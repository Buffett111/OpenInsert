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
    private static System.Collections.Generic.IEnumerable<Control> Descendants(Control parent)
    {
        foreach (Control c in parent.Controls)
        {
            yield return c;
            foreach (var child in Descendants(c)) yield return child;
        }
    }
}
