using System.ComponentModel;
using System.Runtime.InteropServices;

namespace OpenInsert.Windows.Platform;

public static class Orthography
{
    public static string Convert(string text, string languageId)
    {
        if (text.Length == 0) return text;
        uint flags = languageId switch { "zh-Hant" => 0x04000000, "zh-Hans" => 0x02000000, _ => 0 };
        if (flags == 0) return text;
        var locale = languageId == "zh-Hant" ? "zh-TW" : "zh-CN";
        var length = LCMapStringEx(locale, flags, text, text.Length, null, 0, 0, 0, 0);
        if (length == 0) throw new Win32Exception(Marshal.GetLastWin32Error(), "Chinese script conversion failed.");
        var output = new char[length];
        var written = LCMapStringEx(locale, flags, text, text.Length, output, output.Length, 0, 0, 0);
        if (written == 0) throw new Win32Exception(Marshal.GetLastWin32Error(), "Chinese script conversion failed.");
        return new string(output, 0, written);
    }

    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern int LCMapStringEx(string locale, uint flags, string source, int sourceLength,
        [Out] char[]? destination, int destinationLength, nint version, nint reserved, nint sortHandle);
}
