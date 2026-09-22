namespace OpenInsert.Core;

internal sealed record LiveTiming
{
    internal TimeSpan Setup { get; init; } = TimeSpan.FromSeconds(20);
    internal TimeSpan Send { get; init; } = TimeSpan.FromSeconds(5);
    internal TimeSpan Finalization { get; init; } = TimeSpan.FromSeconds(20);
    internal TimeSpan QuietDrain { get; init; } = TimeSpan.FromSeconds(1);
}

/// <summary>
/// One push-to-talk session accepting mono, signed 16-bit little-endian PCM at 16 kHz.
/// Finalization follows the macOS implementation: after activityEnd succeeds, require an
/// authoritative inputTranscription and one second without transcription changes or unresolved
/// interim text. Other models additionally require turnComplete. The quiet interval is a bounded
/// heuristic, not a Google protocol guarantee; interim text is never promoted to final text.
/// </summary>
public sealed class GeminiLiveSession : IAsyncDisposable
{
    private enum Phase { Idle, Starting, Streaming, Finishing, Complete, Failed, Cancelled }
    private readonly object gate = new();
    private readonly string apiKey;
    private readonly DictationOptions options;
    private readonly Action<string>? onPartial;
    private readonly ILiveTransport transport;
    private readonly LiveTiming timing;
    private readonly CancellationTokenSource lifetime = new();
    private readonly CancellationToken lifetimeToken;
    private readonly TaskCompletionSource setupComplete = new(TaskCreationOptions.RunContinuationsAsynchronously);
    private readonly TaskCompletionSource<string> finished = new(TaskCreationOptions.RunContinuationsAsynchronously);
    private readonly LiveTranscript transcript = new();
    private Phase phase;
    private Exception? failure;
    private string? result;
    private Task sendTail = Task.CompletedTask;
    private CancellationTokenSource? drain;
    private int sentAudioBytes;
    private int finalSegments;
    private int revision;
    private bool setupReceived, endDispatched, endSent, turnComplete, disposed, closed;

    public GeminiLiveSession(string apiKey, DictationOptions options, Action<string>? onPartial = null)
        : this(apiKey, options, CreateTransport(apiKey, options), new LiveTiming(), onPartial) { }

    private static ILiveTransport CreateTransport(string apiKey, DictationOptions options)
    {
        ValidateConfiguration(apiKey, options);
        return new WebSocketLiveTransport();
    }

    internal GeminiLiveSession(string apiKey, DictationOptions options, ILiveTransport transport, LiveTiming timing, Action<string>? onPartial = null)
    {
        this.apiKey = GeminiApiKey.Validate(apiKey);
        ValidateConfiguration(apiKey, options);
        this.options = options;
        this.transport = transport;
        this.timing = timing;
        this.onPartial = onPartial;
        lifetimeToken = lifetime.Token;
        Observe(setupComplete.Task);
        Observe(finished.Task);
    }

    /// <summary>Validates local options without opening the microphone or making a request.</summary>
    public static void ValidateConfiguration(string apiKey, DictationOptions options)
    {
        GeminiApiKey.Validate(apiKey);
        GeminiProtocol.Setup(options);
        if (options.Polish) GeminiProtocol.ValidateModel(options.CleanupModel);
    }

    public async Task StartAsync(CancellationToken cancellationToken = default)
    {
        cancellationToken.ThrowIfCancellationRequested();
        lock (gate)
        {
            if (phase != Phase.Idle || disposed) throw failure ?? GeminiException.State();
            phase = Phase.Starting;
        }
        using var cancellation = cancellationToken.Register(() => Fail(new OperationCanceledException()));
        using var setupDeadline = CancellationTokenSource.CreateLinkedTokenSource(lifetimeToken);
        setupDeadline.CancelAfter(timing.Setup);
        try
        {
            var connecting = transport.ConnectAsync(apiKey, setupDeadline.Token);
            Observe(connecting);
            await connecting.WaitAsync(setupDeadline.Token).ConfigureAwait(false);
            _ = ReceiveLoopAsync();
            Task setupWrite;
            lock (gate) setupWrite = QueueLocked(GeminiProtocol.Setup(options));
            await setupWrite.WaitAsync(setupDeadline.Token).ConfigureAwait(false);
            await setupComplete.Task.WaitAsync(setupDeadline.Token).ConfigureAwait(false);
            Task startWrite;
            lock (gate) startWrite = QueueLocked(GeminiProtocol.ActivityStart);
            await startWrite.WaitAsync(setupDeadline.Token).ConfigureAwait(false);
            lock (gate)
            {
                if (phase != Phase.Starting) throw failure ?? GeminiException.State();
                phase = Phase.Streaming;
            }
            cancellationToken.ThrowIfCancellationRequested();
        }
        catch (Exception error)
        {
            var safe = setupDeadline.IsCancellationRequested && !lifetimeToken.IsCancellationRequested
                ? new GeminiException("Gemini Live did not become ready within 20 seconds. Nothing was inserted.", true)
                : CurrentFailure(error, cancellationToken);
            Fail(safe);
            throw safe;
        }
    }

    /// <summary>Await each audio write to apply backpressure to the microphone stream.</summary>
    public async Task SendAudioAsync(ReadOnlyMemory<byte> audio, CancellationToken cancellationToken = default)
    {
        cancellationToken.ThrowIfCancellationRequested();
        if (audio.IsEmpty || audio.Length % 2 != 0 || audio.Length > 32000)
            throw new GeminiException("Audio chunks must contain 1–16,000 mono PCM16 samples at 16 kHz.");
        Task write;
        lock (gate)
        {
            if (phase != Phase.Streaming || disposed) throw failure ?? GeminiException.State();
            if (sentAudioBytes > 3840000 - audio.Length)
            {
                var error = new GeminiException("Dictation reached the 120-second audio limit. Nothing was inserted.");
                Fail(error);
                throw error;
            }
            sentAudioBytes += audio.Length;
            // Encoding under the state lock both copies the caller-owned buffer and preserves
            // ordering relative to FinishAsync, including concurrent callers.
            write = QueueLocked(GeminiProtocol.Audio(audio));
        }
        using var cancellation = cancellationToken.Register(() => Fail(new OperationCanceledException()));
        try
        {
            await write.WaitAsync(lifetimeToken).ConfigureAwait(false);
            cancellationToken.ThrowIfCancellationRequested();
            lock (gate) if (failure is not null) throw failure;
        }
        catch (Exception error)
        {
            var safe = CurrentFailure(error, cancellationToken);
            Fail(safe);
            throw safe;
        }
    }

    public async Task<string> FinishAsync(CancellationToken cancellationToken = default)
    {
        cancellationToken.ThrowIfCancellationRequested();
        lock (gate)
        {
            if (phase == Phase.Complete && result is not null) return result;
            if (phase != Phase.Streaming || disposed) throw failure ?? GeminiException.State();
            phase = Phase.Finishing;
            turnComplete = false;
            _ = QueueLocked(GeminiProtocol.ActivityEnd, marksEnd: true);
        }
        using var cancellation = cancellationToken.Register(() => Fail(new OperationCanceledException()));
        try
        {
            var text = await finished.Task.WaitAsync(timing.Finalization, cancellationToken).ConfigureAwait(false);
            cancellationToken.ThrowIfCancellationRequested();
            return text;
        }
        catch (Exception error)
        {
            var safe = error is TimeoutException ? GeminiException.FinalTimeout() : CurrentFailure(error, cancellationToken);
            Fail(safe);
            throw safe;
        }
    }

    private Task QueueLocked(string message, bool marksEnd = false)
    {
        var next = SendAfterAsync(sendTail, message, marksEnd);
        sendTail = next;
        Observe(next);
        return next;
    }

    private async Task SendAfterAsync(Task previous, string message, bool marksEnd)
    {
        // Ensure state updates and sendTail assignment occur before any transport callbacks.
        await Task.Yield();
        try
        {
            await previous.WaitAsync(lifetimeToken).ConfigureAwait(false);
            lifetimeToken.ThrowIfCancellationRequested();
            using var deadline = CancellationTokenSource.CreateLinkedTokenSource(lifetimeToken);
            deadline.CancelAfter(timing.Send);
            if (marksEnd) lock (gate) endDispatched = true;
            var operation = transport.SendAsync(message, deadline.Token);
            Observe(operation);
            try { await operation.WaitAsync(deadline.Token).ConfigureAwait(false); }
            catch (OperationCanceledException) when (!lifetimeToken.IsCancellationRequested)
            { throw new GeminiException("Sending audio to Gemini timed out. Nothing was inserted.", true); }
            if (marksEnd)
            {
                lock (gate)
                {
                    if (phase != Phase.Finishing) return;
                    endSent = true;
                    revision++;
                    ScheduleDrainLocked();
                }
            }
        }
        catch (Exception error)
        {
            var safe = CurrentFailure(error);
            Fail(safe);
            throw safe;
        }
    }

    private async Task ReceiveLoopAsync()
    {
        try
        {
            long receivedBytes = 0;
            while (!lifetimeToken.IsCancellationRequested)
            {
                var bytes = await transport.ReceiveAsync(lifetimeToken).ConfigureAwait(false);
                lifetimeToken.ThrowIfCancellationRequested();
                receivedBytes += bytes.Length;
                if (receivedBytes > 16000000) throw GeminiException.Oversized();
                var message = LiveEvent.Parse(bytes);
                string? preview = null;
                lock (gate)
                {
                    if (phase is not (Phase.Starting or Phase.Streaming or Phase.Finishing)) return;
                    if (message.Rejected) throw GeminiException.Rejected();
                    if (message.Interrupted) throw new GeminiException("Gemini interrupted the transcription. Nothing was inserted.", true);
                    if (message.GoAway) throw GeminiException.Network();
                    if (message.SetupComplete)
                    {
                        if (phase != Phase.Starting || setupReceived || message.FinalText is not null || message.InterimText is not null || message.TurnComplete)
                            throw GeminiException.InvalidResponse();
                        setupReceived = true;
                        setupComplete.TrySetResult();
                        continue;
                    }
                    if (phase == Phase.Starting)
                    {
                        if (message.FinalText is not null || message.InterimText is not null || message.TurnComplete)
                            throw GeminiException.InvalidResponse();
                        continue;
                    }
                    if (transcript.Consume(message)) preview = transcript.Preview;
                    if (message.FinalText is not null) finalSegments++;
                    if (phase == Phase.Finishing && endDispatched)
                    {
                        if (message.TurnComplete) turnComplete = true;
                        if (message.FinalText is not null || message.InterimText is not null || message.TurnComplete)
                        {
                            revision++;
                            ScheduleDrainLocked();
                        }
                    }
                }
                if (preview is not null)
                {
                    // A failed UI observer cannot become a transport error or insert text.
                    try { onPartial?.Invoke(preview); } catch { }
                }
            }
        }
        catch (Exception error) { Fail(CurrentFailure(error)); }
    }

    private bool CanFinalizeLocked => endSent && !transcript.HasInterim &&
        (options.LiveModel == "gemini-3.5-transcribe-live" ? finalSegments > 0 : turnComplete);

    private void ScheduleDrainLocked()
    {
        drain?.Cancel();
        drain?.Dispose();
        drain = null;
        if (!CanFinalizeLocked) return;
        drain = CancellationTokenSource.CreateLinkedTokenSource(lifetimeToken);
        _ = DrainAsync(revision, drain.Token);
    }

    private async Task DrainAsync(int expectedRevision, CancellationToken token)
    {
        try
        {
            await Task.Delay(timing.QuietDrain, token).ConfigureAwait(false);
            string text;
            lock (gate)
            {
                if (phase != Phase.Finishing || revision != expectedRevision || !CanFinalizeLocked || token.IsCancellationRequested) return;
                text = transcript.Committed.Trim();
                if (text.Length == 0) throw GeminiException.Empty();
                result = text;
                phase = Phase.Complete;
            }
            Close();
            finished.TrySetResult(text);
        }
        catch (OperationCanceledException) { }
        catch (Exception error) { Fail(CurrentFailure(error)); }
    }

    private Exception CurrentFailure(Exception error, CancellationToken callerToken = default)
    {
        if (callerToken.IsCancellationRequested) return new OperationCanceledException(callerToken);
        lock (gate) return failure ?? GeminiException.Redact(error);
    }

    private void Fail(Exception error)
    {
        lock (gate)
        {
            if (phase is Phase.Complete or Phase.Failed or Phase.Cancelled) return;
            failure = error;
            phase = error is OperationCanceledException ? Phase.Cancelled : Phase.Failed;
        }
        Close();
        setupComplete.TrySetException(error);
        finished.TrySetException(error);
    }

    private void Close()
    {
        lock (gate)
        {
            if (closed) return;
            closed = true;
            transport.Abort();
            lifetime.Cancel();
        }
    }

    private static void Observe(Task task) => _ = task.ContinueWith(t => _ = t.Exception, CancellationToken.None,
        TaskContinuationOptions.OnlyOnFaulted | TaskContinuationOptions.ExecuteSynchronously, TaskScheduler.Default);

    public ValueTask DisposeAsync()
    {
        lock (gate)
        {
            if (disposed) return ValueTask.CompletedTask;
            disposed = true;
            Fail(new OperationCanceledException());
            // Another failure may have set its state immediately before this lock was acquired.
            // Close under the same lock before disposing native transport resources.
            Close();
            transport.Dispose();
            drain?.Dispose();
            drain = null;
        }
        // Cancellation callbacks and all public waiters have been released by Fail/Close.
        // Keep the small CTS alive for any late transport completion still observing its token.
        return ValueTask.CompletedTask;
    }
}
