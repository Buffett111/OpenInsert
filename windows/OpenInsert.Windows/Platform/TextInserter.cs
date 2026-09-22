using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Windows.Automation;
using System.Windows.Automation.Text;

namespace OpenInsert.Windows.Platform;

public sealed record TargetSnapshot
{
    internal TargetSnapshot(nint window, int processId, int[] runtimeId, TextPatternRange[]? selection, bool terminal)
    { Window = window; ProcessId = processId; RuntimeId = runtimeId; Selection = selection; IsTerminal = terminal; }
    internal nint Window { get; }
    internal int ProcessId { get; }
    internal int[] RuntimeId { get; }
    internal TextPatternRange[]? Selection { get; }
    internal bool IsTerminal { get; }
}
public sealed record DeliveryResult(bool Pasted, string Message, bool Copied = false);

/// <summary>One normal paste into the original verified field. Never reads text from the destination.</summary>
public sealed class TextInserter : IDisposable
{
    private readonly NativeClipboard clipboard = new();
    private bool delivering;
    public event Action? PasteDispatched;
    /// <summary>Capability metadata only; excludes destination contents, names, titles and paths.</summary>
    public string LastTargetDiagnostic { get; private set; } = "capture: not-requested";

    public TargetSnapshot? CaptureTarget()
    {
        RequireSta();
        var diagnostic = new TargetDiagnostic("capture");
        try
        {
            var window = GetForegroundWindow();
            if (window == 0) throw new TargetVerificationException("no-foreground-window");
            GetWindowThreadProcessId(window, out var processId);
            if (processId == Environment.ProcessId) throw new TargetVerificationException("own-application");
            var element = AutomationElement.FocusedElement;
            VerifyEditable(element, processId, diagnostic);
            var id = element.GetRuntimeId();
            if (id.Length == 0) throw new TargetVerificationException("missing-runtime-id");
            var selection = ReadSelection(element, diagnostic);
            var terminal = IsTerminal(processId, element);
            if (GetForegroundWindow() != window) throw new TargetVerificationException("foreground-window-changed");
            LastTargetDiagnostic = diagnostic.Describe("captured");
            return new TargetSnapshot(window, processId, id, selection, terminal);
        }
        catch (Exception error) when (IsAccessibilityFailure(error))
        {
            LastTargetDiagnostic = diagnostic.Describe(FailureCategory(error));
            return null;
        }
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

    private bool Validate(TargetSnapshot target)
    {
        var diagnostic = new TargetDiagnostic("validate");
        try
        {
            if (GetForegroundWindow() != target.Window) throw new TargetVerificationException("foreground-window-changed");
            GetWindowThreadProcessId(target.Window, out var processId);
            if (processId != target.ProcessId) throw new TargetVerificationException("window-process-changed");
            var current = AutomationElement.FocusedElement;
            VerifyEditable(current, target.ProcessId, diagnostic);
            if (!current.GetRuntimeId().SequenceEqual(target.RuntimeId))
                throw new TargetVerificationException("focused-element-changed");
            if (!SelectionMatches(target.Selection, ReadSelection(current, diagnostic)))
                throw new TargetVerificationException("selection-changed");
            if (GetForegroundWindow() != target.Window) throw new TargetVerificationException("foreground-window-changed");
            return true;
        }
        catch (Exception error) when (IsAccessibilityFailure(error))
        {
            LastTargetDiagnostic = diagnostic.Describe(FailureCategory(error));
            return false;
        }
    }

    private static void VerifyEditable(AutomationElement? element, int processId, TargetDiagnostic? diagnostic = null)
    {
        if (element is null) throw new TargetVerificationException("no-focused-element");
        var current = element.Current;
        diagnostic?.RecordElement(current, processId);
        if (current.ProcessId != processId) throw new TargetVerificationException("focused-process-mismatch");
        if (current.IsPassword) throw new TargetVerificationException("password-field");
        if (!current.IsEnabled) throw new TargetVerificationException("disabled-field");
        if (!current.HasKeyboardFocus) throw new TargetVerificationException("no-keyboard-focus");
        if (current.ControlType != ControlType.Edit && current.ControlType != ControlType.Document
            && current.ControlType != ControlType.ComboBox)
            throw new TargetVerificationException("unsupported-control-type");
        var writable = false;
        var hasValue = element.TryGetCurrentPattern(ValuePattern.Pattern, out var value);
        if (diagnostic != null) diagnostic.ValuePattern = hasValue ? "supported" : "unsupported";
        if (hasValue)
        {
            var readOnly = ((ValuePattern)value).Current.IsReadOnly;
            if (diagnostic != null) diagnostic.ValuePattern = readOnly ? "read-only" : "writable";
            if (readOnly) throw new TargetVerificationException("value-read-only");
            writable = true; // Never request ValuePattern.Current.Value.
        }
        var hasText = element.TryGetCurrentPattern(TextPattern.Pattern, out var pattern);
        if (diagnostic != null) diagnostic.TextPattern = hasText ? "supported" : "unsupported";
        if (hasText)
        {
            var attribute = ((TextPattern)pattern).DocumentRange.GetAttributeValue(TextPattern.IsReadOnlyAttribute);
            if (diagnostic != null) diagnostic.TextPattern = attribute switch
            { true => "read-only", false => "writable", _ => "read-only-unknown" };
            if (attribute is true) throw new TargetVerificationException("text-read-only");
            writable |= attribute is false;
        }
        if (!writable) throw new TargetVerificationException("editability-unverified");
    }

    internal static bool SelectionMatches(TextPatternRange[]? captured, TextPatternRange[]? current)
    {
        if (captured is null) return current is null;
        if (current is null || captured.Length != current.Length) return false;
        return captured.Zip(current).All(pair => SameEndpoints(pair.First, pair.Second));
    }

    private static bool SameEndpoints(TextPatternRange left, TextPatternRange right) =>
        left.CompareEndpoints(TextPatternRangeEndpoint.Start, right, TextPatternRangeEndpoint.Start) == 0
        && left.CompareEndpoints(TextPatternRangeEndpoint.End, right, TextPatternRangeEndpoint.End) == 0;

    private static TextPatternRange[]? ReadSelection(AutomationElement element, TargetDiagnostic? diagnostic = null)
    {
        // Position metadata only. No GetText, Value, Name or document contents are queried.
        // A writable ValuePattern is sufficient evidence of an editor; Chromium and
        // other providers do not always expose TextPattern/selection. Match macOS's
        // optional selection check, without dropping identity or editability checks.
        // Available selection metadata must still match, including its availability.
        if (!element.TryGetCurrentPattern(TextPattern.Pattern, out var value))
        {
            if (diagnostic != null) diagnostic.Selection = "unsupported";
            return null;
        }
        var pattern = (TextPattern)value;
        if (pattern.SupportedTextSelection == SupportedTextSelection.None)
        {
            if (diagnostic != null) diagnostic.Selection = "unsupported";
            return null;
        }
        if (diagnostic != null) diagnostic.Selection = "supported";
        try
        {
            var selected = pattern.GetSelection();
            if (selected.Length is 0 or > 64)
            {
                if (diagnostic != null) diagnostic.Selection = "ranges-unavailable";
                return null;
            }
            // Retain independent insertion-point/selection ranges. Chromium's editable
            // ranges need not normalize to DocumentRange.Start when moved by characters,
            // so converting them to offsets can reject even an empty focused composer.
            // Direct endpoint comparisons preserve caret-change checks without reading text.
            var ranges = selected.Select(range => range.Clone()).ToArray();
            if (!ranges.Zip(selected).All(pair => SameEndpoints(pair.First, pair.Second)))
            {
                if (diagnostic != null) diagnostic.Selection = "comparison-unavailable";
                return null;
            }
            if (diagnostic != null) diagnostic.Selection = "captured";
            return ranges;
        }
        catch (Exception error) when (IsUnsupportedRangeOperation(error))
        {
            // Some otherwise writable providers omit optional selection operations.
            // A later loss of ranges already captured still fails SelectionMatches.
            if (diagnostic != null) diagnostic.Selection = "unsupported";
            return null;
        }
    }

    private static bool IsUnsupportedRangeOperation(Exception error) => error is NotSupportedException or NotImplementedException
        || error is COMException { HResult: unchecked((int)0x80004001) or unchecked((int)0x80040204) }; // E_NOTIMPL / UIA_E_NOTSUPPORTED

    private sealed class TargetVerificationException(string category) : InvalidOperationException(category)
    {
        internal string Category { get; } = category;
    }

    private static string FailureCategory(Exception error) => error switch
    {
        TargetVerificationException verification => verification.Category,
        ElementNotAvailableException => "element-unavailable",
        UnauthorizedAccessException => "access-denied",
        NotSupportedException or NotImplementedException => "accessibility-not-supported",
        COMException => "accessibility-com-failure",
        System.ComponentModel.Win32Exception => "accessibility-native-failure",
        ArgumentException => "accessibility-invalid-argument",
        _ => "accessibility-invalid-operation"
    };

    private sealed class TargetDiagnostic(string phase)
    {
        private string element = "element=unavailable";
        internal string ValuePattern { get; set; } = "not-queried";
        internal string TextPattern { get; set; } = "not-queried";
        internal string Selection { get; set; } = "not-queried";
        internal void RecordElement(AutomationElement.AutomationElementInformation current, int processId)
        {
            // FrameworkId is capability metadata. Allow known identifiers only, so a
            // custom provider cannot accidentally surface arbitrary text in diagnostics.
            var framework = current.FrameworkId switch
            {
                "Chrome" or "Chromium" or "Win32" or "WinForm" or "WPF" or "XAML"
                    or "DirectUI" or "InternetExplorer" or "Mozilla" => current.FrameworkId,
                "" => "unspecified",
                _ => "other"
            };
            element = $"control={current.ControlType.ProgrammaticName}; framework={framework}; "
                + $"processMatch={current.ProcessId == processId}; focus={current.HasKeyboardFocus}; "
                + $"enabled={current.IsEnabled}; password={current.IsPassword}";
        }
        internal string Describe(string outcome) => $"{phase}: {outcome}; {element}; "
            + $"value={ValuePattern}; text={TextPattern}; selection={Selection}";
    }

    private static bool IsAccessibilityFailure(Exception error) => error is ElementNotAvailableException
        or InvalidOperationException or COMException or UnauthorizedAccessException or ArgumentException
        or NotSupportedException or NotImplementedException or System.ComponentModel.Win32Exception;

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
