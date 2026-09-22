using System.Runtime.InteropServices;
using System.Threading.Channels;

namespace OpenInsert.Windows.Platform;

/// <summary>Single-use, in-memory 16 kHz mono PCM capture. LevelChanged runs on the capture worker.</summary>
public sealed class MicrophoneRecorder : IDisposable
{
    private const uint CallbackEvent = 0x00050000;
    private const uint HeaderDone = 1;
    private const int BufferBytes = 3200;
    private readonly Channel<byte[]> channel = Channel.CreateBounded<byte[]>(new BoundedChannelOptions(128)
    {
        SingleReader = true, SingleWriter = true, FullMode = BoundedChannelFullMode.Wait
    });
    private readonly AutoResetEvent available = new(false);
    private readonly ManualResetEvent stopping = new(false);
    private readonly List<Buffer> buffers = [];
    private nint device;
    private Task? worker;
    private bool started, disposed, nativeResourcesQuarantined;
    private static readonly List<object> QuarantinedResources = [];
    private int nextBuffer;
    private static readonly uint HeaderSize = (uint)Marshal.SizeOf<WaveHeader>();

    public ChannelReader<byte[]> Audio => channel.Reader;
    public event Action<float>? LevelChanged;

    public void Start()
    {
        ObjectDisposedException.ThrowIf(disposed, this);
        if (started) throw new InvalidOperationException("A microphone recorder can only be started once.");
        started = true;
        try
        {
            var format = new WaveFormat { FormatTag = 1, Channels = 1, SamplesPerSecond = 16000,
                AverageBytesPerSecond = 32000, BlockAlign = 2, BitsPerSample = 16 };
            Check(waveInOpen(out device, uint.MaxValue, ref format,
                available.SafeWaitHandle.DangerousGetHandle(), 0, CallbackEvent), "open the microphone");
            for (var index = 0; index < 6; index++)
            {
                var buffer = new Buffer();
                buffers.Add(buffer);
                Check(waveInPrepareHeader(device, buffer.Header, HeaderSize), "prepare microphone capture");
                buffer.Prepared = true;
                Check(waveInAddBuffer(device, buffer.Header, HeaderSize), "queue microphone capture");
            }
            Check(waveInStart(device), "start the microphone");
            worker = Task.Factory.StartNew(Capture, CancellationToken.None,
                TaskCreationOptions.LongRunning, TaskScheduler.Default);
        }
        catch (Exception error)
        {
            ReleaseDevice();
            channel.Writer.TryComplete(error);
            throw;
        }
    }

    /// <summary>Returns all pending PCM, including the final partial buffer, before completing Audio.</summary>
    public void Stop()
    {
        if (disposed) return;
        stopping.Set();
        worker?.GetAwaiter().GetResult();
        if (!started) channel.Writer.TryComplete();
    }

    private void Capture()
    {
        Exception? failure = null;
        try
        {
            WaitHandle[] signals = [stopping, available];
            while (WaitHandle.WaitAny(signals) != 0)
                Drain(requeue: true);
            Check(waveInReset(device), "stop the microphone");
            Drain(requeue: false);
        }
        catch (Exception error) { failure = error; }
        finally
        {
            // CALLBACK_EVENT means there is no managed driver callback that can outlive cleanup.
            // The event and headers remain alive until reset, unprepare and close are complete.
            var cleanupFailure = ReleaseDevice();
            failure ??= cleanupFailure;
            channel.Writer.TryComplete(failure);
        }
    }

    private void Drain(bool requeue)
    {
        for (var count = 0; count < buffers.Count; count++)
        {
            var buffer = buffers[nextBuffer];
            var header = Marshal.PtrToStructure<WaveHeader>(buffer.Header);
            if ((header.Flags & HeaderDone) == 0) break;
            var length = checked((int)header.BytesRecorded);
            if (length > BufferBytes || (length & 1) != 0)
                throw new IOException("The microphone returned malformed PCM audio.");
            if (length > 0)
            {
                var audio = new byte[length];
                Marshal.Copy(buffer.Data, audio, 0, length);
                if (!channel.Writer.TryWrite(audio))
                    throw new IOException("Audio delivery is too slow. Recording stopped before audio could be lost.");
                double energy = 0;
                for (var i = 0; i < length; i += 2)
                {
                    var sample = (short)(audio[i] | audio[i + 1] << 8) / 32768.0;
                    energy += sample * sample;
                }
                // A UI subscriber must post, never synchronously invoke, to the UI thread.
                try { LevelChanged?.Invoke((float)Math.Sqrt(energy / (length / 2))); }
                catch { /* Meter subscribers must not interrupt capture. */ }
            }
            nextBuffer = (nextBuffer + 1) % buffers.Count;
            if (requeue && !stopping.WaitOne(0))
            {
                header.BytesRecorded = 0;
                Marshal.StructureToPtr(header, buffer.Header, false);
                Check(waveInAddBuffer(device, buffer.Header, HeaderSize), "continue microphone capture");
            }
            else
            {
                // Clearing DONE prevents a later drain from duplicating a returned buffer.
                header.Flags &= ~HeaderDone;
                header.BytesRecorded = 0;
                Marshal.StructureToPtr(header, buffer.Header, false);
            }
        }
    }

    private Exception? ReleaseDevice()
    {
        if (device != 0)
        {
            uint failure = waveInReset(device);
            foreach (var buffer in buffers)
            {
                if (!buffer.Prepared) continue;
                var result = waveInUnprepareHeader(device, buffer.Header, HeaderSize);
                if (result != 0) failure = result;
            }
            var closeResult = waveInClose(device);
            if (closeResult != 0) failure = closeResult;
            if (failure != 0)
            {
                // A broken/unplugged driver can refuse reset or unprepare. Never free memory
                // or close an event that such a driver could still reference. Keep these rare
                // failed resources alive until process exit rather than risk use-after-free.
                lock (QuarantinedResources)
                    QuarantinedResources.Add(new object[] { available, buffers.ToArray(), device });
                nativeResourcesQuarantined = true;
                buffers.Clear();
                device = 0;
                return new IOException($"The microphone driver did not release its capture buffers (Windows audio error {failure}). Restart OpenInsert before recording again.");
            }
            device = 0;
        }
        foreach (var buffer in buffers) buffer.Dispose();
        buffers.Clear();
        return null;
    }

    private static void Check(uint result, string operation)
    {
        if (result != 0)
            throw new IOException($"Unable to {operation} (Windows audio error {result}). Check Settings > Privacy & security > Microphone and your default input device.");
    }

    public void Dispose()
    {
        if (disposed) return;
        Stop();
        disposed = true;
        if (!nativeResourcesQuarantined) available.Dispose();
        stopping.Dispose();
    }

    private sealed class Buffer : IDisposable
    {
        public readonly nint Data = Marshal.AllocHGlobal(BufferBytes);
        public readonly nint Header = Marshal.AllocHGlobal((int)HeaderSize);
        public bool Prepared;
        public Buffer() => Marshal.StructureToPtr(new WaveHeader { Data = Data, BufferLength = BufferBytes }, Header, false);
        public void Dispose() { Marshal.FreeHGlobal(Header); Marshal.FreeHGlobal(Data); }
    }

    [StructLayout(LayoutKind.Sequential, Pack = 2)]
    private struct WaveFormat
    {
        public ushort FormatTag, Channels;
        public uint SamplesPerSecond, AverageBytesPerSecond;
        public ushort BlockAlign, BitsPerSample, ExtraSize;
    }
    [StructLayout(LayoutKind.Sequential)]
    private struct WaveHeader
    {
        public nint Data;
        public uint BufferLength, BytesRecorded;
        public nuint User;
        public uint Flags, Loops;
        public nint Next;
        public nuint Reserved;
    }
    [DllImport("winmm.dll")] private static extern uint waveInOpen(out nint device, uint id, ref WaveFormat format, nint callback, nuint instance, uint flags);
    [DllImport("winmm.dll")] private static extern uint waveInPrepareHeader(nint device, nint header, uint size);
    [DllImport("winmm.dll")] private static extern uint waveInUnprepareHeader(nint device, nint header, uint size);
    [DllImport("winmm.dll")] private static extern uint waveInAddBuffer(nint device, nint header, uint size);
    [DllImport("winmm.dll")] private static extern uint waveInStart(nint device);
    [DllImport("winmm.dll")] private static extern uint waveInReset(nint device);
    [DllImport("winmm.dll")] private static extern uint waveInClose(nint device);
}
