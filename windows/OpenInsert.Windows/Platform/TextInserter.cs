using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Windows.Automation;
using System.Windows.Automation.Text;

namespace OpenInsert.Windows.Platform;

public sealed record TargetSnapshot
{
    internal TargetSnapshot(nint window, int processId, int[] runtimeId, SelectionRange[] selection, bool terminal)
    { Window = window; ProcessId = processId; RuntimeId = runtimeId; Selection = selection; IsTerminal = terminal; }
    internal nint Window { get; }
    internal int ProcessId { get; }
    internal int[] RuntimeId { get; }
    internal SelectionRange[] Selection { get; }
    internal bool IsTerminal { get; }
}
internal readonly record struct SelectionRange(int Start, int End);
public sealed record DeliveryResult(bool Pasted, string Message, bool Copied = false);

/// <summary>One normal paste into the original verified field. Never reads text from the destination.</summary>
public sealed class TextInserter : IDisposable
{
    private readonly NativeClipboard clipboard = new();
    private bool delivering;
    public event Action? PasteDispatched;

    public TargetSnapshot? CaptureTarget()
    {
        RequireSta();
        try
        {
            var window = GetForegroundWindow();
            if (window == 0) return null;
            GetWindowThreadProcessId(window, out var processId);
            if (processId == Environment.ProcessId) return null;
            var element = AutomationElement.FocusedElement;
            VerifyEditable(element, processId);
            var id = element.GetRuntimeId();
            if (id.Length == 0) return null;
            var selection = ReadSelection(element);
            var terminal = IsTerminal(processId, element);
            if (GetForegroundWindow() != window) return null;
            return new TargetSnapshot(window, processId, id, selection, terminal);
        }
        catch (Exception error) when (IsAccessibilityFailure(error)) { return null; }
    }

    public async Task<DeliveryResult> DeliverAsync(string text, TargetSnapshot? target,
        bool restoreClipboard, CancellationToken cancellationToken)
    {
        RequireSta();
        if (delivering) return new(false, "A previous paste is still completing.");
        if (string.IsNullOrWhiteSpace(text)) return new(false, "No text was recognized.");
        if (text.Contains('\0')) return new(false, "The result contains an unsupported control character. Copy it manually after reviewing it.");
        cancellationToken.ThrowIfCancellationRequested();
        delivering = true;
        try
        {
            // Read and eagerly duplicate every existing format even for automatic permanent copy.
            // A failed read or a concurrent clipboard write must never trigger a copy fallback.
            using var previous = clipboard.Capture();
            if (target is null || !Validate(target))
            {
                clipboard.WriteText(text, previous);
                return new(false, "The original input field could not be verified. The result was copied to the clipboard; paste it manually.", Copied: true);
            }
            if (target.IsTerminal && text.Any(IsTerminalControl))
                return new(false, "Automatic paste of multiline text or tabs into a terminal was blocked. Review the result and copy it manually.");

            // Hotkey key-up can lag transcription completion; wait briefly without synthesizing
            // releases for keys the user physically holds.
            var deadline = Environment.TickCount64 + 1500;
            while (AnyModifierHeld() && Environment.TickCount64 < deadline)
                await Task.Delay(20, cancellationToken);
            cancellationToken.ThrowIfCancellationRequested();
            if (AnyModifierHeld()) return new(false, "Release the modifier keys, then copy the result manually.");
            if (!Validate(target))
            {
                clipboard.WriteText(text, previous);
                return new(false, "The original input field changed. The result was copied to the clipboard; paste it manually.", Copied: true);
            }

            var ownedSequence = clipboard.WriteText(text, previous);
            if (!Validate(target) || AnyModifierHeld() || cancellationToken.IsCancellationRequested)
            {
                if (!clipboard.RestoreIfOwned(previous, ownedSequence))
                    return new(false, "The clipboard changed before paste. Newer clipboard contents were preserved; copy the result manually.");
                cancellationToken.ThrowIfCancellationRequested();
                return new(false, "The input field or keyboard state changed before paste. Copy the result manually.");
            }
            if (!clipboard.IsOwned(ownedSequence))
                return new(false, "The clipboard changed before paste. Newer clipboard contents were preserved; copy the result manually.");

            var input = new[] { Key(0x11), Key(0x56), Key(0x56, up: true), Key(0x11, up: true) };
            var sent = SendInput((uint)input.Length, input, Marshal.SizeOf<Input>());
            if (sent != input.Length)
            {
                // SendInput can be blocked by UIPI. Do not retry the paste or escalate privileges.
                // Release only our synthetic keys if the OS accepted part of the sequence.
                if (sent > 0)
                {
                    var release = new[] { Key(0x56, up: true), Key(0x11, up: true) };
                    SendInput((uint)release.Length, release, Marshal.SizeOf<Input>());
                }
                await Task.Delay(800); // A partial sequence may already have dispatched Ctrl+V.
                clipboard.RestoreIfOwned(previous, ownedSequence);
                return new(false, "Windows blocked the paste. The destination may require the same privilege level. Review the result before manually pasting; delivery was not retried.");
            }
            try { PasteDispatched?.Invoke(); } catch { /* A UI callback must not retry paste. */ }
            // Cancellation cannot shorten the destination's opportunity to read the clipboard.
            await Task.Delay(800);
            if (restoreClipboard) clipboard.RestoreIfOwned(previous, ownedSequence);
            return new(true, "Paste was requested in the original input field.");
        }
        catch (NativeClipboard.ClipboardFailure error) { return new(false, error.Message); }
        finally { delivering = false; }
    }

    private static bool Validate(TargetSnapshot target)
    {
        try
        {
            if (GetForegroundWindow() != target.Window) return false;
            GetWindowThreadProcessId(target.Window, out var processId);
            if (processId != target.ProcessId) return false;
            var current = AutomationElement.FocusedElement;
            VerifyEditable(current, target.ProcessId);
            return current.GetRuntimeId().SequenceEqual(target.RuntimeId)
                && ReadSelection(current).SequenceEqual(target.Selection)
                && GetForegroundWindow() == target.Window;
        }
        catch (Exception error) when (IsAccessibilityFailure(error)) { return false; }
    }

    private static void VerifyEditable(AutomationElement? element, int processId)
    {
        if (element is null) throw new InvalidOperationException("No focused input field.");
        var current = element.Current;
        if (current.ProcessId != processId || current.IsPassword || !current.IsEnabled || !current.HasKeyboardFocus)
            throw new InvalidOperationException("The focused input field is not safe for paste.");
        if (current.ControlType != ControlType.Edit && current.ControlType != ControlType.Document
            && current.ControlType != ControlType.ComboBox)
            throw new InvalidOperationException("The focused control is not an editable text field.");
        var writable = false;
        if (element.TryGetCurrentPattern(ValuePattern.Pattern, out var value))
        {
            if (((ValuePattern)value).Current.IsReadOnly) throw new InvalidOperationException("The field is read-only.");
            writable = true; // Never request ValuePattern.Current.Value.
        }
        if (element.TryGetCurrentPattern(TextPattern.Pattern, out var pattern))
        {
            var attribute = ((TextPattern)pattern).DocumentRange.GetAttributeValue(TextPattern.IsReadOnlyAttribute);
            if (attribute is true) throw new InvalidOperationException("The field is read-only.");
            writable |= attribute is false;
        }
        if (!writable) throw new InvalidOperationException("Editability could not be verified.");
    }

    private static SelectionRange[] ReadSelection(AutomationElement element)
    {
        // Position metadata only. No GetText, Value, Name or document contents are queried.
        if (!element.TryGetCurrentPattern(TextPattern.Pattern, out var value))
            throw new InvalidOperationException("Selection positions are unavailable.");
        var pattern = (TextPattern)value;
        if (pattern.SupportedTextSelection == SupportedTextSelection.None)
            throw new InvalidOperationException("Selection positions are unavailable.");
        var selected = pattern.GetSelection();
        if (selected.Length is 0 or > 64) throw new InvalidOperationException("Selection positions are unavailable.");
        var document = pattern.DocumentRange;
        return selected.Select(range => new SelectionRange(
            Offset(range, TextPatternRangeEndpoint.Start, document),
            Offset(range, TextPatternRangeEndpoint.End, document))).ToArray();
    }

    private static int Offset(TextPatternRange selection, TextPatternRangeEndpoint endpoint, TextPatternRange document)
    {
        var cursor = selection.Clone();
        var moved = cursor.MoveEndpointByUnit(endpoint, TextUnit.Character, -1_000_000);
        if (cursor.CompareEndpoints(endpoint, document, TextPatternRangeEndpoint.Start) != 0)
            throw new InvalidOperationException("The selection is too large to verify safely.");
        return checked(-moved);
    }

    private static bool IsAccessibilityFailure(Exception error) => error is ElementNotAvailableException
        or InvalidOperationException or COMException or UnauthorizedAccessException or ArgumentException
        or System.ComponentModel.Win32Exception;

    private static bool IsTerminal(int processId, AutomationElement element)
    {
        using var process = Process.GetProcessById(processId);
        var name = process.ProcessName.ToLowerInvariant();
        var className = element.Current.ClassName.ToLowerInvariant();
        return new[] { "windowsterminal", "openconsole", "conhost", "powershell", "pwsh", "cmd", "mintty", "alacritty", "wezterm", "warp", "putty", "kitty", "hyper" }
            .Any(terminal => name.Contains(terminal, StringComparison.Ordinal))
            || className.Contains("terminal", StringComparison.Ordinal)
            || className.Contains("console", StringComparison.Ordinal);
    }

    private static bool IsTerminalControl(char character) => character is '\t' or '\r' or '\n' or '\v' or '\f' or '\u0085' or '\u2028' or '\u2029';
    private static bool AnyModifierHeld() => new[] { 0x10, 0x11, 0x12, 0x5B, 0x5C }.Any(key => (GetAsyncKeyState(key) & 0x8000) != 0);
    private static void RequireSta()
    {
        if (Thread.CurrentThread.GetApartmentState() != ApartmentState.STA)
            throw new InvalidOperationException("Text insertion must run on the UI STA thread.");
    }
    public void Dispose() => clipboard.Dispose();

    private static Input Key(ushort virtualKey, bool up = false) => new()
    { Type = 1, Data = new InputUnion { Keyboard = new KeyboardInput { VirtualKey = virtualKey, Flags = up ? 2u : 0u } } };
    [StructLayout(LayoutKind.Sequential)] private struct Input { public uint Type; public InputUnion Data; }
    [StructLayout(LayoutKind.Explicit)] private struct InputUnion
    { [FieldOffset(0)] public KeyboardInput Keyboard; [FieldOffset(0)] public MouseInput Mouse; }
    [StructLayout(LayoutKind.Sequential)] private struct KeyboardInput
    { public ushort VirtualKey, ScanCode; public uint Flags, Time; public nuint ExtraInfo; }
    [StructLayout(LayoutKind.Sequential)] private struct MouseInput
    { public int X, Y; public uint MouseData, Flags, Time; public nuint ExtraInfo; }
    [DllImport("user32.dll")] private static extern nint GetForegroundWindow();
    [DllImport("user32.dll")] private static extern uint GetWindowThreadProcessId(nint window, out int processId);
    [DllImport("user32.dll")] private static extern short GetAsyncKeyState(int virtualKey);
    [DllImport("user32.dll", SetLastError = true)] private static extern uint SendInput(uint count, Input[] input, int size);
}
