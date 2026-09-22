namespace OpenInsert.Core;

public static class GeminiApiKey
{
    public const int MaximumBytes = 8192;

    /// <summary>Transport validation only; Google decides whether an opaque key is authorized.</summary>
    public static string Validate(string value)
    {
        var key = (value ?? "").Trim(' ', '\t', '\r', '\n');
        if (key.Length == 0) throw new GeminiException("Paste your complete Gemini API key in Settings.");
        if (key.Length > MaximumBytes) throw new GeminiException("The API key exceeds the 8 KiB limit. Paste only the key.");
        if (key.Any(c => c is ' ' or '\t' or '\r' or '\n' or '\v' or '\f'))
            throw new GeminiException("The API key contains whitespace. Copy the complete key again.");
        if (key.Any(c => c < 33 || c > 126))
            throw new GeminiException("The API key contains an invisible, control or non-ASCII character. Copy the key again.");
        return key;
    }
}
