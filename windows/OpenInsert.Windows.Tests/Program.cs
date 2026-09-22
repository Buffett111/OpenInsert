using System;
using System.Drawing;
using System.Drawing.Imaging;
using System.IO;
using System.Linq;
using System.Windows.Forms;
using OpenInsert.Windows;

internal static class Program
{
    [STAThread]
    private static int Main(string[] args)
    {
        Application.EnableVisualStyles();
        Application.SetHighDpiMode(HighDpiMode.PerMonitorV2);
        int passed = 0;
        void Check(bool ok, string name)
        {
            if (!ok) throw new Exception(name);
            Console.WriteLine("PASS " + name);
            passed++;
        }
        try
        {
            var defaults = new AppSettings();
            defaults.Validate();
            Check(defaults.ShortcutModifiers == 2 && defaults.ShortcutKey == 32 && defaults.ShortcutName == "Ctrl + Space", "Windows default is Ctrl + Space");
            Check(!defaults.CloudConsent, "Cloud processing requires explicit opt-in");
            Check(defaults.RestoreClipboard, "Clipboard restoration defaults on");
            Check(!ShortcutRecorderDialog.IsValid(0, 32), "Bare Space is rejected");
            Check(!ShortcutRecorderDialog.IsValid(4, 32), "Shift-only Space is rejected");
            Check(ShortcutRecorderDialog.IsValid(0, 112), "Standalone F1 is allowed");
            Check(!ShortcutRecorderDialog.IsValid(2, 27), "Escape remains cancellation");
            Check(!ShortcutRecorderDialog.IsValid(2, 17), "Modifier-only shortcut is rejected");
            Check(defaults.Options.LanguageHint.Contains("do not translate"), "Writing preference preserves spoken languages");
            Check((defaults with { WritingLanguage = "custom", CustomLanguage = "" }).Options.LanguageHint.Contains("original character"), "Empty custom writing hint uses automatic");
            foreach (string bad in new[] { "../model", "gemini-test\r\n", "https://example.com" })
            {
                bool rejected = false;
                try { (defaults with { LiveModel = bad }).Validate(); } catch (ArgumentException) { rejected = true; }
                Check(rejected, "Invalid model is rejected");
            }
            CheckOverlay(Check, args.Length > 0 ? args[0] : null);
            foreach (string language in new[] { "zh-Hant", "en" })
            {
                using var form = new MainForm(defaults with { InterfaceLanguage = language }, smokeTest: true);
                form.Opacity = 0;
                form.ShowInTaskbar = false;
                form.Show(); // Hidden-opacity, non-activating form: creates all child layouts for rendering.
                _ = form.Handle;
                form.CreateControl();
                Check(form.HasRequiredControls, "Preferences, connection and results exist in " + language);
                var tabs = Descendants(form).OfType<TabControl>().Single();
                foreach (TabPage page in tabs.TabPages)
                {
                    tabs.SelectedTab = page;
                    page.CreateControl();
                    form.PerformLayout();
                    Check(page.Controls.Count > 0, "Page layout " + page.Text);
                    if (args.Length > 0)
                    {
                        Directory.CreateDirectory(args[0]);
                        using var preview = new Bitmap(form.Width, form.Height);
                        form.DrawToBitmap(preview, new Rectangle(0, 0, form.Width, form.Height));
                        preview.Save(Path.Combine(args[0], $"windows-{language}-{tabs.SelectedIndex}.png"), ImageFormat.Png);
                    }
                }
            }
            Console.WriteLine($"{passed} Windows UI/settings checks passed. No microphone, clipboard, credentials or network used.");
            return 0;
        }
        catch (Exception ex) { Console.Error.WriteLine("FAIL " + ex.Message); return 1; }
    }
    private static void CheckOverlay(Action<bool, string> check, string? outputDirectory)
    {
        check(DictationCaption.Latest(" \r\n ", _ => true) == "", "Empty live transcript stays empty");
        check(DictationCaption.Latest(" Hello\t world\r\n你好  ", _ => true) == "Hello world 你好",
            "Streaming caption normalizes incoming whitespace");
        check(DictationCaption.Latest("first second latest", text => text.Length <= 8) == "… latest",
            "Long preview keeps newest words, not the beginning");
        check(DictationCaption.Latest("old 👩🏽‍💻e\u0301最新", text =>
            System.Globalization.StringInfo.ParseCombiningCharacters(text).Length <= 6) == "… 👩🏽‍💻e\u0301最新",
            "Tail truncation preserves emoji and combining characters");
        check(DictationCaption.Latest(new string('字', 500), _ => true) == "… " + new string('字', 420),
            "Unbounded live transcript is limited to recent text");

        const string latest = "最新辨識內容會即時出現在這裡。";
        string longTranscript = string.Concat(Enumerable.Repeat("這是一段較長的語音輸入，畫面應持續顯示最新說出的內容。", 30)) + latest;
        foreach (int dpi in new[] { 96, 120, 144, 192 })
        {
            using var measureBitmap = new Bitmap(1, 1);
            measureBitmap.SetResolution(dpi, dpi);
            using var graphics = Graphics.FromImage(measureBitmap);
            int width = 440 * dpi / 96;
            var empty = DictationOverlayFrame.Create(graphics, dpi, width, "正在聆聽 Listening", "", true, false);
            check(empty.Status.Length == 0 && empty.StatusBounds.IsEmpty && empty.CaptionBounds.IsEmpty,
                $"Recording without text shows waveform only at {dpi} DPI");
            var shortFrame = DictationOverlayFrame.Create(graphics, dpi, width, "正在聆聽 Listening", "你好，這是即時辨識文字。", true, false);
            var longFrame = DictationOverlayFrame.Create(graphics, dpi, width, "正在聆聽 Listening", longTranscript, true, false);
            using var font = DictationOverlayFrame.CreateCaptionFont(dpi);
            check(longFrame.StatusBounds.IsEmpty && longFrame.Status.Length == 0,
                $"Recording reserves transcript area instead of a listening label at {dpi} DPI");
            check(longFrame.Caption.EndsWith(latest, StringComparison.Ordinal) && longFrame.Caption.StartsWith("… ", StringComparison.Ordinal),
                $"Long recording displays latest streaming suffix at {dpi} DPI");
            check(empty.Size.Height < shortFrame.Size.Height && shortFrame.Size.Height < longFrame.Size.Height,
                $"Overlay grows with caption length at {dpi} DPI");
            check(longFrame.CaptionBounds.Top > longFrame.WaveformBounds.Bottom
                && longFrame.CaptionBounds.Height <= font.Height * 4
                && longFrame.CaptionBounds.Bottom < longFrame.Size.Height,
                $"Four-line caption fits below waveform with bottom padding at {dpi} DPI");
            var measured = TextRenderer.MeasureText(graphics, longFrame.Caption, font,
                new Size(longFrame.CaptionBounds.Width, int.MaxValue), DictationOverlayFrame.CaptionFlags);
            check(measured.Width <= longFrame.CaptionBounds.Width && measured.Height <= longFrame.CaptionBounds.Height,
                $"Every displayed transcript line fits at {dpi} DPI");
            var finishing = DictationOverlayFrame.Create(graphics, dpi, width, "正在整理文字…", latest, false, false);
            var error = DictationOverlayFrame.Create(graphics, dpi, width, "Connection lost. Please retry.", "", false, true);
            check(!finishing.StatusBounds.IsEmpty && finishing.WaveformBounds.IsEmpty && finishing.Caption.EndsWith(latest, StringComparison.Ordinal),
                $"Finishing message and transcript remain visible at {dpi} DPI");
            check(error.Error && !error.StatusBounds.IsEmpty && error.Status.Contains("Connection lost"),
                $"Errors remain visible at {dpi} DPI");

            using var image = new Bitmap(longFrame.Size.Width, longFrame.Size.Height);
            image.SetResolution(dpi, dpi);
            using (var canvas = Graphics.FromImage(image))
                longFrame.Draw(canvas, Enumerable.Range(0, 96).Select(i => (float)(0.02 + 0.65 * Math.Pow(Math.Sin(i * 0.3), 2))));
            bool hasCaptionPixels = false;
            for (int y = longFrame.CaptionBounds.Top; y < longFrame.CaptionBounds.Bottom && !hasCaptionPixels; y++)
                for (int x = longFrame.CaptionBounds.Left; x < longFrame.CaptionBounds.Right; x++)
                {
                    var pixel = image.GetPixel(x, y);
                    if (pixel.R > 180 && pixel.G > 180 && pixel.B > 180) { hasCaptionPixels = true; break; }
                }
            check(hasCaptionPixels, $"Caption text is actually rendered at {dpi} DPI");
            if (outputDirectory != null)
            {
                Directory.CreateDirectory(outputDirectory);
                image.Save(Path.Combine(outputDirectory, $"windows-live-transcript-{dpi}dpi.png"), ImageFormat.Png);
            }
        }
    }
    private static System.Collections.Generic.IEnumerable<Control> Descendants(Control parent)
    {
        foreach (Control c in parent.Controls)
        {
            yield return c;
            foreach (var child in Descendants(c)) yield return child;
        }
    }
}
