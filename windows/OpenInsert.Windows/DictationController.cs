using System.Diagnostics;
using OpenInsert.Core;
using OpenInsert.Windows.Platform;

namespace OpenInsert.Windows;

internal enum DictationState { Idle, Preparing, Recording, Transcribing, Polishing, Inserting, Testing }

/// <summary>Serializes one dictation on the UI STA. No transcript or microphone data is persisted.</summary>
internal sealed class DictationController : IDisposable
{
    internal const int MaximumRecordingSeconds = 119;
    private readonly SynchronizationContext context;
    private readonly TextInserter inserter = new();
    private CancellationTokenSource? operation;
    private CancellationTokenSource? cleanupCancellation;
    private TaskCompletionSource? stop;
    private Task? running;
    private bool firstPress;
    private bool skipCleanup;
    private bool disposed;
    public DictationState State { get; private set; }
    public bool IsBusy => State != DictationState.Idle;
    public string LastText { get; private set; } = "";
    public string Preview { get; private set; } = "";
    public string Status { get; private set; } = "";
    public bool LastStatusIsError { get; private set; }
    public bool Pasted { get; private set; }
    public string TargetDiagnostic => inserter.LastTargetDiagnostic;
    public event Action? Changed;
    public event Action<float>? LevelChanged;
    public event Action? PasteDispatched;
    public Func<AppSettings> Settings { get; set; }
    private string T(string zh, string en) => Settings().InterfaceLanguage == "en" ? en : zh;

    public DictationController(Func<AppSettings> settings)
    {
        context = SynchronizationContext.Current ?? throw new InvalidOperationException("A Windows UI context is required.");
        Settings = settings;
        inserter.PasteDispatched += () => { Pasted = true; PasteDispatched?.Invoke(); };
    }

    public void Press()
    {
        firstPress = !IsBusy;
        if (firstPress) Start();
        else if (State is DictationState.Preparing or DictationState.Recording) Stop();
    }

    public void Release(TimeSpan duration)
    {
        if (firstPress && duration.TotalMilliseconds >= 350) Stop();
        firstPress = false;
    }

    public void UncertainRelease()
    {
        if (firstPress && State is (DictationState.Preparing or DictationState.Recording))
        {
            Cancel();
            SetStatus(T("快捷鍵放開時間不確定，已取消；請再試一次。", "Shortcut release timing was uncertain; dictation was cancelled. Try again."), true);
        }
        firstPress = false;
    }

    public void Start()
    {
        if (IsBusy || disposed) return;
        var settings = Settings() with { };
        BeginOperation(DictationState.Preparing, T("正在連線…", "Connecting…"));
        stop = new(TaskCreationOptions.RunContinuationsAsynchronously);
        running = RunAsync(settings, operation!);
    }

    public void Stop() => stop?.TrySetResult();
    public void Cancel() { operation?.Cancel(); stop?.TrySetResult(); }
    public async Task CancelAndWaitAsync()
    {
        Cancel();
        if (running != null) await running;
    }
    public void SkipCleanup()
    {
        if (State != DictationState.Polishing) return;
        skipCleanup = true;
        cleanupCancellation?.Cancel();
    }

    private void BeginOperation(DictationState state, string status)
    {
        operation = new();
        State = state;
        Preview = "";
        Pasted = false;
        skipCleanup = false;
        SetStatus(status);
    }

    private string RequireConnection(AppSettings settings)
    {
        settings.Validate();
        if (!settings.CloudConsent)
            throw new InvalidOperationException(T("請先在「連線」同意將音訊傳送到 Google。", "First consent to sending audio to Google in Connection settings."));
        var key = CredentialStore.Load();
        if (string.IsNullOrWhiteSpace(key))
            throw new InvalidOperationException(T("請先儲存自己的 Gemini API 金鑰。", "Save your own Gemini API key first."));
        return GeminiApiKey.Validate(key);
    }

    private async Task RunAsync(AppSettings settings, CancellationTokenSource owner)
    {
        var ct = owner.Token;
        try
        {
            var key = RequireConnection(settings);
            var target = inserter.CaptureTarget();
            await using var session = new GeminiLiveSession(key, settings.Options, partial =>
            {
                context.Post(_ =>
                {
                    if (operation != owner || ct.IsCancellationRequested || disposed ||
                        State is not (DictationState.Recording or DictationState.Transcribing)) return;
                    Preview = Orthography.Convert(partial, settings.WritingLanguage);
                    Changed?.Invoke();
                }, null);
            });
            await session.StartAsync(ct);
            ct.ThrowIfCancellationRequested();
            if (stop!.Task.IsCompleted)
            {
                SetStatus(T("連線完成前已結束操作。請重試，等候綠色聲波出現後再說話。", "Recording ended before the connection was ready. Try again and wait for the green waveform before speaking."));
                return;
            }
            using var recorder = new MicrophoneRecorder();
            recorder.LevelChanged += value => context.Post(_ =>
            {
                if (operation == owner && State == DictationState.Recording && !ct.IsCancellationRequested)
                    LevelChanged?.Invoke(value);
            }, null);
            recorder.Start();
            State = DictationState.Recording;
            var recordingClock = Stopwatch.StartNew();
            using var recordingTimer = new System.Windows.Forms.Timer { Interval = 250 };
            void UpdateRecordingStatus()
            {
                if (operation != owner || State != DictationState.Recording || ct.IsCancellationRequested) return;
                string elapsed = recordingClock.Elapsed.ToString(@"mm\:ss");
                SetStatus(T($"錄音 {elapsed} · 最長約 2 分鐘；完成後才進行文字整理。", $"Recording {elapsed} · Up to 2 minutes; text cleanup runs after recording."));
            }
            recordingTimer.Tick += (_, _) => UpdateRecordingStatus();
            UpdateRecordingStatus();
            recordingTimer.Start();
            async Task PumpAsync()
            {
                await foreach (var chunk in recorder.Audio.ReadAllAsync(ct).ConfigureAwait(false))
                    await session.SendAudioAsync(chunk, ct).ConfigureAwait(false);
            }
            var pump = PumpAsync();
            try
            {
                // End before the 120-second wire limit to leave room for native capture tails.
                var limit = Task.Delay(TimeSpan.FromSeconds(MaximumRecordingSeconds), ct);
                var completed = await Task.WhenAny(stop!.Task, pump, limit);
                ct.ThrowIfCancellationRequested();
                if (completed == pump)
                {
                    await pump;
                    throw new InvalidOperationException(T("麥克風已中斷，請重試。", "Microphone capture ended unexpectedly. Try again."));
                }
                recorder.Stop();
                recordingTimer.Stop();
                State = DictationState.Transcribing;
                SetStatus(T("正在完成辨識…", "Finalizing transcription…"));
                try { await pump.WaitAsync(TimeSpan.FromSeconds(10), ct); }
                catch (TimeoutException)
                {
                    owner.Cancel();
                    throw new InvalidOperationException(T("音訊傳送太慢，已取消本次錄音。請檢查網路後重試。", "Audio delivery was too slow. Dictation was cancelled; check your network and try again."));
                }
                ct.ThrowIfCancellationRequested();
            }
            finally
            {
                recordingTimer.Stop();
                recorder.Stop();
                // Observe sender failures even if capture was cancelled first.
                if (!pump.IsCompleted) owner.Cancel();
                try { await pump; } catch (Exception) { }
            }
            var timer = Stopwatch.StartNew();
            var text = Orthography.Convert(await session.FinishAsync(ct), settings.WritingLanguage);
            ct.ThrowIfCancellationRequested();
            LastText = text;
            Preview = text;
            string fallback = "";
            var asrSeconds = timer.Elapsed.TotalSeconds;
            if (settings.Polish)
            {
                State = DictationState.Polishing;
                SetStatus(T("錄音已結束，正在整理文字（可略過）…", "Recording finished. Cleaning up text (you can skip)…"));
                using var cleanupOwner = CancellationTokenSource.CreateLinkedTokenSource(ct);
                cleanupCancellation = cleanupOwner;
                using var cleanup = new GeminiCleanupClient();
                try
                {
                    text = Orthography.Convert(await cleanup.PolishAsync(text, key, settings.Options, cleanupOwner.Token), settings.WritingLanguage);
                }
                catch (OperationCanceledException) when (skipCleanup && !ct.IsCancellationRequested)
                {
                    fallback = T("已略過整理，使用辨識原文。", "Cleanup skipped; using finalized transcription.");
                }
                catch (GeminiException ex) when (ex.IsTransient && !ct.IsCancellationRequested)
                {
                    fallback = T("整理暫時無法使用，改用辨識原文。", "Cleanup temporarily unavailable; using finalized transcription.");
                }
                finally { cleanupCancellation = null; }
            }
            ct.ThrowIfCancellationRequested();
            LastText = text;
            State = DictationState.Inserting;
            SetStatus(T("正在送出文字…", "Delivering text…"));
            var delivery = await inserter.DeliverAsync(text, target, settings.RestoreClipboard, ct);
            var delivered = delivery.Pasted ? T("已請求貼上。", "Paste requested.") : delivery.Copied
                ? T("已複製完成文字，可按 Ctrl + V 貼上。", "Finalized text copied. Press Ctrl + V to paste.")
                : delivery.Message;
            SetStatus((fallback.Length > 0 ? fallback + " " : "") + delivered + T($" 辨識收尾 {asrSeconds:F1} 秒。", $" ASR finalization {asrSeconds:F1}s."), !delivery.Pasted && !delivery.Copied);
        }
        catch (OperationCanceledException) { SetStatus(T("已取消。", "Cancelled.")); }
        catch (Exception ex) { SetStatus(SafeError(ex), true); }
        finally { EndOperation(owner); }
    }

    public void CheckConnection()
    {
        if (IsBusy || disposed) return;
        BeginOperation(DictationState.Testing, T("正在檢查 Gemini 連線（不錄音）…", "Checking Gemini connection (no microphone)…"));
        var settings = Settings() with { };
        running = CheckConnectionAsync(settings, operation!);
    }

    private async Task CheckConnectionAsync(AppSettings settings, CancellationTokenSource owner)
    {
        try
        {
            var key = RequireConnection(settings);
            await using var session = new GeminiLiveSession(key, settings.Options with { Vocabulary = "" });
            await session.StartAsync(owner.Token);
            owner.Token.ThrowIfCancellationRequested();
            SetStatus(T("Gemini 接受連線與模型設定；尚未測試語音、整理或貼上。", "Gemini accepted the connection and model setup. Audio, cleanup and insertion were not tested."));
        }
        catch (OperationCanceledException) { SetStatus(T("已取消。", "Cancelled.")); }
        catch (Exception ex) { SetStatus(SafeError(ex), true); }
        finally { EndOperation(owner); }
    }

    public void TestInsertion()
    {
        if (IsBusy || disposed) return;
        BeginOperation(DictationState.Testing, T("5 秒後測試貼上，請切換到空白文字文件。", "Testing paste in 5 seconds. Switch to a disposable text document."));
        running = TestInsertionAsync(operation!);
    }

    private async Task TestInsertionAsync(CancellationTokenSource owner)
    {
        try
        {
            await Task.Delay(5_000, owner.Token);
            var target = inserter.CaptureTarget();
            LastText = "OpenInsert Windows 語音輸入測試。Hello, Windows!";
            var result = await inserter.DeliverAsync(LastText, target, Settings().RestoreClipboard, owner.Token);
            SetStatus(result.Pasted ? T("已請求貼上測試文字，請檢查目標。", "Test paste requested. Check the target document.")
                : result.Copied ? T("找不到可驗證的輸入位置，測試文字已複製。", "No verifiable input target. Test text copied.")
                : result.Message, !result.Pasted && !result.Copied);
        }
        catch (OperationCanceledException) { SetStatus(T("已取消。", "Cancelled.")); }
        catch (Exception ex) { SetStatus(SafeError(ex), true); }
        finally { EndOperation(owner); }
    }

    private void EndOperation(CancellationTokenSource owner)
    {
        if (operation == owner)
        {
            operation = null;
            stop = null;
            State = DictationState.Idle;
            Preview = "";
            Changed?.Invoke();
        }
        owner.Dispose();
    }
    public void ClearResult() { LastText = ""; Changed?.Invoke(); }
    public void SetStatus(string text, bool error = false)
    {
        Status = text;
        LastStatusIsError = error;
        if (!disposed) Changed?.Invoke();
    }
    private string SafeError(Exception ex) => ex switch
    {
        GeminiException or InvalidOperationException or ArgumentException or System.ComponentModel.Win32Exception => ex.Message,
        UnauthorizedAccessException => T("無法存取設定或麥克風，請檢查 Windows 權限。", "Access denied. Check Windows settings and microphone permissions."),
        _ => T("操作失敗，請檢查麥克風、網路或重試。沒有自動插入文字。", "The operation failed. Check your microphone or network and try again. No text was automatically inserted.")
    };
    public void Dispose()
    {
        if (disposed) return;
        disposed = true;
        Cancel();
        if (running == null || running.IsCompleted) inserter.Dispose();
        else _ = DisposeAfterRunAsync(running);
    }
    private async Task DisposeAfterRunAsync(Task task)
    {
        try { await task; }
        finally { inserter.Dispose(); }
    }
}
