using System.ComponentModel;
using System.Runtime.InteropServices;
using System.Security.Cryptography;
using System.Text;
using OpenInsert.Core;

namespace OpenInsert.Windows.Platform;

/// <summary>DPAPI user-scoped credentials. No plaintext key is written to disk or logged.</summary>
public static class CredentialStore
{
    private static readonly string DirectoryPath = Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "OpenInsert");
    private static readonly string FilePath = Path.Combine(DirectoryPath, "gemini-key.dpapi");

    public static string? Load()
    {
        if (!File.Exists(FilePath)) return null;
        var protectedBytes = File.ReadAllBytes(FilePath);
        if (protectedBytes.Length > 65536) throw new IOException("The saved credential file is invalid.");
        var clear = Transform(protectedBytes, protect: false);
        try { return GeminiApiKey.Validate(Encoding.UTF8.GetString(clear)); }
        finally { CryptographicOperations.ZeroMemory(clear); }
    }

    public static void Save(string key)
    {
        var validated = GeminiApiKey.Validate(key);
        var clear = Encoding.UTF8.GetBytes(validated);
        byte[] protectedBytes;
        try { protectedBytes = Transform(clear, protect: true); }
        finally { CryptographicOperations.ZeroMemory(clear); }
        Directory.CreateDirectory(DirectoryPath);
        var temporary = Path.Combine(DirectoryPath, $".credential-{Guid.NewGuid():N}.tmp");
        try
        {
            File.WriteAllBytes(temporary, protectedBytes);
            File.Move(temporary, FilePath, overwrite: true);
        }
        finally { if (File.Exists(temporary)) File.Delete(temporary); }
    }

    public static void Delete() => File.Delete(FilePath);

    private static byte[] Transform(byte[] bytes, bool protect)
    {
        var input = new DataBlob { Length = bytes.Length, Data = Marshal.AllocHGlobal(bytes.Length) };
        DataBlob output = default;
        try
        {
            Marshal.Copy(bytes, 0, input.Data, bytes.Length);
            // CRYPTPROTECT_UI_FORBIDDEN only: omitting LOCAL_MACHINE binds the key to this user.
            var success = protect
                ? CryptProtectData(ref input, "OpenInsert Gemini API key", 0, 0, 0, 1, out output)
                : CryptUnprotectData(ref input, 0, 0, 0, 0, 1, out output);
            if (!success) throw new Win32Exception(Marshal.GetLastWin32Error(), "Windows could not access the saved API key for this user.");
            var result = new byte[output.Length];
            Marshal.Copy(output.Data, result, 0, result.Length);
            return result;
        }
        finally
        {
            Zero(input.Data, input.Length);
            Marshal.FreeHGlobal(input.Data);
            if (output.Data != 0) { Zero(output.Data, output.Length); LocalFree(output.Data); }
        }
    }

    private static void Zero(nint pointer, int count)
    {
        for (var offset = 0; offset < count; offset++) Marshal.WriteByte(pointer, offset, 0);
    }
    [StructLayout(LayoutKind.Sequential)] private struct DataBlob { public int Length; public nint Data; }
    [DllImport("crypt32.dll", CharSet = CharSet.Unicode, SetLastError = true)] [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool CryptProtectData(ref DataBlob input, string description, nint entropy, nint reserved, nint prompt, uint flags, out DataBlob output);
    [DllImport("crypt32.dll", SetLastError = true)] [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool CryptUnprotectData(ref DataBlob input, nint description, nint entropy, nint reserved, nint prompt, uint flags, out DataBlob output);
    [DllImport("kernel32.dll")] private static extern nint LocalFree(nint pointer);
}
