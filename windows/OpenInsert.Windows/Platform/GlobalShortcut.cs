using System.ComponentModel;
using System.Runtime.InteropServices;

namespace OpenInsert.Windows.Platform;

/// <summary>Registers one shortcut without observing unrelated keystrokes. Create and dispose on the UI thread.</summary>
public sealed class GlobalShortcut : System.Windows.Forms.NativeWindow, IDisposable
{
    private const int HotKeyMessage = 0x0312;
    private const int ReleaseMessage = 0x8001;
    private const uint NoRepeat = 0x4000;
    private const long HoldBoundaryMs = 350;
    private readonly object gate = new();
    private readonly Queue<TimeSpan?> releases = new();
    private System.Threading.Timer? releaseTimer;
    private int nextId = 100, registeredId;
    private uint modifiers, key;
    private long pressedAt, lastHeldAt;
    private nint pressedWindow;
    private bool tracking, disposed;

    public event Action? Pressed;
    public event Action<TimeSpan>? Released;
    public event Action? UncertainRelease;

    public GlobalShortcut()
    {
        CreateHandle(new System.Windows.Forms.CreateParams { Caption = "OpenInsert shortcut", Parent = new nint(-3) });
    }

    public void Register(uint modifiers, uint virtualKey)
    {
        ObjectDisposedException.ThrowIf(disposed, this);
        if ((modifiers & ~15u) != 0 || virtualKey is 0 or > 254)
            throw new ArgumentOutOfRangeException(nameof(virtualKey), "Choose a valid shortcut key and modifiers.");
        if (registeredId != 0 && this.modifiers == modifiers && key == virtualKey) return;
        var candidateId = nextId++;
        // Acquire the replacement first. On conflict the existing shortcut remains registered.
        if (!RegisterHotKey(Handle, candidateId, modifiers | NoRepeat, virtualKey))
            throw new Win32Exception(Marshal.GetLastWin32Error(), "This shortcut is already in use. Choose another shortcut.");
        if (registeredId != 0) UnregisterHotKey(Handle, registeredId);
        lock (gate) { if (tracking) Finish(null); }
        registeredId = candidateId;
        this.modifiers = modifiers;
        key = virtualKey;
    }

    protected override void WndProc(ref System.Windows.Forms.Message message)
    {
        if (message.Msg == HotKeyMessage && (int)message.WParam == registeredId)
        {
            // WM_HOTKEY is placed at the top of the queue and can overtake our posted release
            // after a slow STA callback. Finish the previous gesture before publishing a new
            // Pressed event, so its release can never be attributed to the new gesture.
            var messageTime = GetMessageTime();
            DrainPendingReleases();
            if (disposed) return;
            lock (gate)
            {
                if (tracking) { Finish(null); return; }
                var now = Environment.TickCount64;
                // WM_HOTKEY may have waited in the queue. Its timestamp uses the same monotonic
                // millisecond clock as GetTickCount; unsigned subtraction also handles 32-bit wrap.
                var age = unchecked((uint)now - (uint)messageTime);
                pressedAt = now - age;
                lastHeldAt = now;
                pressedWindow = GetForegroundWindow();
                tracking = true;
                // Establish the physical state BEFORE invoking UIA or other potentially slow UI
                // subscribers. The background sampler can observe key-up while the STA is busy.
                if (age > 150 || !ChordHeld() || pressedWindow == 0) Finish(null);
                else releaseTimer = new System.Threading.Timer(_ => CheckRelease(), null, 8, 8);
            }
            Pressed?.Invoke();
            return;
        }
        if (message.Msg == ReleaseMessage)
        {
            DrainPendingReleases();
            return;
        }
        base.WndProc(ref message);
    }

    private void DrainPendingReleases()
    {
        while (true)
        {
            TimeSpan? released;
            lock (gate)
            {
                if (disposed || !releases.TryDequeue(out released)) return;
            }
            // Subscribers can stop/cancel work. Invoke only on the STA and outside gate.
            if (released is { } duration) Released?.Invoke(duration);
            else UncertainRelease?.Invoke();
        }
    }

    private void CheckRelease()
    {
        lock (gate)
        {
            if (!tracking || disposed) return;
            var now = Environment.TickCount64;
            if (GetForegroundWindow() != pressedWindow) { Finish(null); return; }
            if (ChordHeld())
            {
                // A long sampler gap could contain an unobserved release and second press.
                if (now - lastHeldAt > 250) { Finish(null); return; }
                lastHeldAt = now;
                return;
            }
            Finish(ClassifyRelease(lastHeldAt - pressedAt, now - pressedAt));
        }
    }

    internal static TimeSpan? ClassifyRelease(long earliest, long latest)
    {
        // Classify only if the entire release interval is on one side of the gesture boundary.
        if (earliest < HoldBoundaryMs && latest >= HoldBoundaryMs)
            return null;
        return TimeSpan.FromMilliseconds(earliest >= HoldBoundaryMs ? earliest : latest);
    }

    private bool ChordHeld() => Down((int)key)
        && ((modifiers & 1) == 0 || Down(0x12))
        && ((modifiers & 2) == 0 || Down(0x11))
        && ((modifiers & 4) == 0 || Down(0x10))
        && ((modifiers & 8) == 0 || Down(0x5B) || Down(0x5C));

    private static bool Down(int key) => (GetAsyncKeyState(key) & 0x8000) != 0;
    // Caller holds gate. Only the configured chord is polled; callbacks are delivered on the STA.
    private void Finish(TimeSpan? duration)
    {
        tracking = false;
        releaseTimer?.Dispose();
        releaseTimer = null;
        releases.Enqueue(duration);
        PostMessage(Handle, ReleaseMessage, 0, 0);
    }

    public void Dispose()
    {
        if (disposed) return;
        lock (gate)
        {
            disposed = true;
            tracking = false;
            releaseTimer?.Dispose();
            releaseTimer = null;
            releases.Clear();
        }
        if (registeredId != 0) UnregisterHotKey(Handle, registeredId);
        DestroyHandle();
    }

    [DllImport("user32.dll", SetLastError = true)] [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool RegisterHotKey(nint window, int id, uint modifiers, uint virtualKey);
    [DllImport("user32.dll")] [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool UnregisterHotKey(nint window, int id);
    [DllImport("user32.dll")] private static extern short GetAsyncKeyState(int virtualKey);
    [DllImport("user32.dll")] private static extern int GetMessageTime();
    [DllImport("user32.dll")] private static extern nint GetForegroundWindow();
    [DllImport("user32.dll")] [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool PostMessage(nint window, int message, nint wParam, nint lParam);
}
