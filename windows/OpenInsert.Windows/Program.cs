using System.Security.Cryptography;
using System.Text;

namespace OpenInsert.Windows;

internal static class Program
{
    [STAThread]
    private static int Main(string[] args)
    {
        ApplicationConfiguration.Initialize();
        // An inert construction check for release/CI. No settings, keys, mic, clipboard or network.
        if (args.Contains("--smoke-test", StringComparer.Ordinal))
        {
            try
            {
                using var form = new MainForm(new AppSettings(), smokeTest: true);
                using var overlay = new DictationOverlay();
                _ = form.Handle;
                _ = overlay.Handle;
                if (!form.HasRequiredControls) return 2;
                return 0;
            }
            catch { return 1; }
        }
        string user = Convert.ToHexString(SHA256.HashData(Encoding.UTF8.GetBytes(Environment.UserDomainName + "\\" + Environment.UserName)))[..20];
        using var instance = new Mutex(true, @"Local\OpenInsert-" + user, out bool first);
        if (!first)
        {
            MessageBox.Show("OpenInsert 已在系統匣執行。\nOpenInsert is already running in the system tray.", "OpenInsert", MessageBoxButtons.OK, MessageBoxIcon.Information);
            return 0;
        }
        var settings = AppSettings.Load(out bool recovered);
        using var main = new MainForm(settings);
        if (recovered)
            main.InitialNotice = settings.InterfaceLanguage == "en"
                ? "Saved settings could not be read. Defaults are loaded; review them before saving."
                : "無法讀取原設定，已載入預設值；請檢查後再儲存。";
        Application.Run(main);
        return 0;
    }
}
