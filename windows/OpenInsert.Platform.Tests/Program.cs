using System;
using System.ComponentModel;
using System.Diagnostics;
using System.Linq;
using System.Reflection;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;
using System.Threading.Tasks;
using System.Windows.Automation;
using OpenInsert.Windows.Platform;
using Forms = System.Windows.Forms;

internal static class Program
{
    private static int checks;
    [STAThread]
    private static int Main(string[] args)
    {
        if (args.FirstOrDefault() == "--target")
        {
            Forms.Application.Run(new TargetForm(args[1]));
            return 0;
        }
        try
        {
            Equal("軟體開發，臺灣", Orthography.Convert("软体开发，台湾", "zh-Hant"), "traditional Chinese conversion");
            Equal("软件开发，台湾", Orthography.Convert("軟件開發，臺灣", "zh-Hans"), "simplified Chinese conversion");
            Equal("Hello 👋", Orthography.Convert("Hello 👋", "en"), "other language unchanged");
            var transform = typeof(CredentialStore).GetMethod("Transform", BindingFlags.NonPublic | BindingFlags.Static)!;
            var original = Encoding.UTF8.GetBytes("not-a-real-key-native-roundtrip");
            var protectedBytes = (byte[])transform.Invoke(null, [original, true])!;
            Check(!original.SequenceEqual(protectedBytes), "DPAPI ciphertext differs");
            var decrypted = (byte[])transform.Invoke(null, [protectedBytes, false])!;
            Check(original.SequenceEqual(decrypted), "DPAPI user roundtrip without modifying saved credentials");
            Check(GlobalShortcut.ClassifyRelease(80, 96)?.TotalMilliseconds == 96, "tap release interval");
            Check(GlobalShortcut.ClassifyRelease(350, 365)?.TotalMilliseconds == 350, "hold release interval");
            Check(GlobalShortcut.ClassifyRelease(342, 358) == null, "uncertain boundary cancels");
            Check(GlobalShortcut.ClassifyRelease(80, 1000) == null, "stalled tap cannot become hold");
            using (var first = new GlobalShortcut())
            using (var second = new GlobalShortcut())
            {
                first.Register(7, 0x87); // Ctrl+Alt+Shift+F24, no input is synthesized.
                second.Register(7, 0x86);
                Throws<Win32Exception>(() => second.Register(7, 0x87), "shortcut conflict reported");
                using var third = new GlobalShortcut();
                Throws<Win32Exception>(() => third.Register(7, 0x86), "old registration retained after conflict");
            }
            if (args.Contains("--clipboard") || args.Contains("--paste")) RunInteractive(args);
            if (args.Contains("--microphone")) Microphone().GetAwaiter().GetResult();
            Console.WriteLine($"PASS {checks} native platform checks");
            return 0;
        }
        catch (Exception error)
        {
            Console.Error.WriteLine(error);
            return 1;
        }
    }

    private static void RunInteractive(string[] args)
    {
        Exception? failure = null;
        using var host = new Forms.Form { Text = "OpenInsert test runner", ShowInTaskbar = false, Opacity = 0 };
        host.Shown += async (_, _) =>
        {
            try { await ClipboardAndPaste(args.Contains("--paste")); }
            catch (Exception error) { failure = error; }
            finally { host.Close(); }
        };
        Forms.Application.Run(host);
        if (failure != null) throw failure;
    }

    private static async Task ClipboardAndPaste(bool paste)
    {
        using var clipboard = new NativeClipboard();
        using var original = clipboard.Capture();
        uint owned = clipboard.WriteText("OpenInsert clipboard fixture", original);
        try
        {
            using var fixture = clipboard.Capture();
            var changed = clipboard.WriteText("OpenInsert newer copy", fixture);
            Throws<NativeClipboard.ClipboardFailure>(() => clipboard.WriteText("must not overwrite", fixture), "concurrent clipboard copy refused");
            Check(!clipboard.RestoreIfOwned(fixture, owned), "restore cannot overwrite newer copy");
            owned = changed;
            await Task.Delay(100);
            Equal("OpenInsert newer copy", Forms.Clipboard.GetText(), "newer clipboard content preserved");
            // Add a binary registered format and Unicode text, then roundtrip every eager format.
            var data = new Forms.DataObject();
            data.SetText("OpenInsert rich fixture", Forms.TextDataFormat.UnicodeText);
            data.SetData("OpenInsert.Test.Bytes", false, new System.IO.MemoryStream([1, 2, 3, 4, 5]));
            Forms.Clipboard.SetDataObject(data, true, 20, 50);
            await Task.Delay(100);
            using var rich = clipboard.Capture();
            owned = clipboard.WriteText("temporary", rich);
            Check(clipboard.RestoreIfOwned(rich, owned), "all readable formats restored");
            owned = GetClipboardSequenceNumber();
            Equal("OpenInsert rich fixture", Forms.Clipboard.GetText(), "Unicode text restored");
            Check(Forms.Clipboard.ContainsData("OpenInsert.Test.Bytes"), "registered binary format restored");
            using var restorePoint = clipboard.Capture();
            owned = clipboard.WriteText("OpenInsert paste baseline", restorePoint);
            if (!paste) return;

            var title = "OpenInsert disposable target " + Guid.NewGuid().ToString("N");
            using var helper = Process.Start(new ProcessStartInfo(Environment.ProcessPath!)
            { UseShellExecute = false, ArgumentList = { "--target", title } })!;
            try
            {
                nint window = 0;
                for (var retry = 0; retry < 50 && window == 0; retry++)
                {
                    await Task.Delay(100);
                    window = FindWindow(null, title);
                }
                Check(window != 0, "disposable helper window exists");
                SetForegroundWindow(window);
                var editor = AutomationElement.FromHandle(window).FindFirst(TreeScope.Descendants,
                    new PropertyCondition(AutomationElement.AutomationIdProperty, "TestEditor"));
                editor?.SetFocus();
                await Task.Delay(200);
                using var inserter = new TextInserter();
                var target = inserter.CaptureTarget();
                if (target == null)
                {
                    var focused = AutomationElement.FocusedElement;
                    Console.WriteLine($"UIA diagnostic: foreground={GetForegroundWindow()}, helper={window}, focused pid={focused?.Current.ProcessId}, type={focused?.Current.ControlType.ProgrammaticName}, keyboard focus={focused?.Current.HasKeyboardFocus}, password={focused?.Current.IsPassword}");
                    if (focused != null && focused.Current.ProcessId == helper.Id)
                        foreach (var methodName in new[] { "VerifyEditable", "ReadSelection" })
                            try
                            {
                                var method = typeof(TextInserter).GetMethod(methodName, BindingFlags.Static | BindingFlags.NonPublic)!;
                                method.Invoke(null, methodName == "VerifyEditable" ? [focused, helper.Id] : [focused]);
                            }
                            catch (Exception diagnostic) { Console.WriteLine(methodName + ": " + diagnostic.InnerException?.Message); }
                }
                Check(target != null, "UIA captures separate-process editor and selection");
                var result = await inserter.DeliverAsync(" pasted ✓", target, true, CancellationToken.None);
                Check(result.Pasted, "paste dispatched exactly once: " + result.Message);
                var pattern = (TextPattern)editor!.GetCurrentPattern(TextPattern.Pattern);
                Equal("seed pasted ✓", pattern.DocumentRange.GetText(-1).TrimEnd('\r', '\n'), "actual text pasted into disposable helper");
                Equal("OpenInsert paste baseline", Forms.Clipboard.GetText(), "clipboard restored after 800 ms");

                target = inserter.CaptureTarget();
                SendMessage(window, 0x8101, 0, 0); // Move helper selection without reading user content.
                result = await inserter.DeliverAsync("selection changed", target, true, CancellationToken.None);
                Check(!result.Pasted && result.Copied, "selection change falls back to persistent copy");
                Equal("selection changed", Forms.Clipboard.GetText(), "safe fallback text retained");
                Equal("seed pasted ✓", pattern.DocumentRange.GetText(-1).TrimEnd('\r', '\n'), "selection change did not insert");
                using var latest = clipboard.Capture();
                owned = clipboard.WriteText("OpenInsert final fixture", latest);
                await HotkeyWhileUiBusy();
            }
            finally { if (!helper.HasExited) { helper.CloseMainWindow(); if (!helper.WaitForExit(3000)) helper.Kill(); } }
        }
        finally
        {
            // Reclaim only our latest known sequence. Any unrelated concurrent user copy wins.
            clipboard.RestoreIfOwned(original, owned);
        }
    }

    private static async Task HotkeyWhileUiBusy()
    {
        using var shortcut = new GlobalShortcut();
        shortcut.Register(7, 0x87);
        var released = new TaskCompletionSource<TimeSpan>();
        shortcut.Pressed += () => Thread.Sleep(650); // Simulates a slow UIA provider on the STA.
        shortcut.Released += duration => released.TrySetResult(duration);
        shortcut.UncertainRelease += () => released.TrySetException(new InvalidOperationException("Unexpected uncertain shortcut release."));
        foreach (byte key in new byte[] { 0x11, 0x12, 0x10, 0x87 }) keybd_event(key, 0, 0, 0);
        var releaseKeys = Task.Run(async () =>
        {
            await Task.Delay(120);
            foreach (byte key in new byte[] { 0x87, 0x10, 0x12, 0x11 }) keybd_event(key, 0, 2, 0);
        });
        try
        {
            var duration = await released.Task.WaitAsync(TimeSpan.FromSeconds(5));
            Check(duration.TotalMilliseconds < 350, "real hotkey tap observed while UI thread blocked for 650 ms");
        }
        finally { await releaseKeys; }
    }

    private static async Task Microphone()
    {
        using var recorder = new MicrophoneRecorder();
        recorder.Start();
        await Task.Delay(260);
        recorder.Stop();
        var bytes = 0;
        var chunks = 0;
        await foreach (var chunk in recorder.Audio.ReadAllAsync())
        {
            Check(chunk.Length > 0 && chunk.Length % 2 == 0, "PCM chunk aligned");
            bytes += chunk.Length;
            chunks++;
        }
        Check(bytes > 0 && chunks >= 2, "microphone tail drained and channel completed");
        Console.WriteLine($"Captured and discarded {bytes} PCM bytes in {chunks} chunks; no audio files created.");
    }

    private static void Check(bool condition, string name)
    { if (!condition) throw new InvalidOperationException("FAIL " + name); checks++; Console.WriteLine("PASS " + name); }
    private static void Equal(string expected, string actual, string name) => Check(expected == actual, name + $" (expected {expected}, got {actual})");
    private static void Throws<T>(Action action, string name) where T : Exception
    { try { action(); } catch (T) { Check(true, name); return; } throw new InvalidOperationException("FAIL " + name); }

    private sealed class TargetForm : Forms.Form
    {
        private readonly Forms.RichTextBox editor = new() { Name = "TestEditor", Text = "seed", Dock = Forms.DockStyle.Fill };
        internal TargetForm(string title)
        {
            Text = title;
            Width = 500; Height = 180;
            Controls.Add(editor);
            Shown += (_, _) => { Activate(); editor.Focus(); editor.Select(editor.TextLength, 0); };
        }
        protected override void WndProc(ref Forms.Message message)
        {
            if (message.Msg == 0x8101) { editor.Select(0, 0); return; }
            base.WndProc(ref message);
        }
    }
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] private static extern nint FindWindow(string? className, string title);
    [DllImport("user32.dll")] [return: MarshalAs(UnmanagedType.Bool)] private static extern bool SetForegroundWindow(nint window);
    [DllImport("user32.dll")] private static extern nint SendMessage(nint window, int message, nint wParam, nint lParam);
    [DllImport("user32.dll")] private static extern uint GetClipboardSequenceNumber();
    [DllImport("user32.dll")] private static extern nint GetForegroundWindow();
    [DllImport("user32.dll")] private static extern void keybd_event(byte key, byte scan, uint flags, nuint extraInfo);
}
