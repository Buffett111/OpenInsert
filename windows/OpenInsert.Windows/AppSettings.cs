using System.Text;
using System.Text.Json;
using OpenInsert.Core;

namespace OpenInsert.Windows;

internal sealed record AppSettings
{
    public string InterfaceLanguage { get; init; } = "zh-Hant";
    public string LiveModel { get; init; } = "gemini-3.5-transcribe-live";
    public string CleanupModel { get; init; } = "gemini-3.5-flash-lite";
    public string WritingLanguage { get; init; } = "zh-Hant";
    public string CustomLanguage { get; init; } = "";
    public string Vocabulary { get; init; } = "";
    public bool Polish { get; init; } = true;
    public bool RestoreClipboard { get; init; } = true;
    public bool CloudConsent { get; init; }
    public uint ShortcutModifiers { get; init; } = 2;
    public uint ShortcutKey { get; init; } = 32;

    public static string DirectoryPath => Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "OpenInsert");
    private static string FilePath => Path.Combine(DirectoryPath, "settings.json");
    public static readonly string[] LanguageIds = ["zh-Hant", "auto", "zh-Hans", "en", "ja", "ko", "custom"];
    public static readonly string[] LanguageNames = ["繁體中文（台灣）", "Automatic / 自動", "简体中文", "English", "日本語", "한국어", "Custom / 自訂"];

    public static AppSettings Load(out bool recovered)
    {
        recovered = false;
        if (!File.Exists(FilePath)) return new();
        try
        {
            if (new FileInfo(FilePath).Length > 128_000) throw new InvalidDataException();
            var value = JsonSerializer.Deserialize<AppSettings>(File.ReadAllText(FilePath)) ?? throw new InvalidDataException();
            value.Validate();
            return value;
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException or JsonException or ArgumentException or GeminiException)
        {
            // Never read keys from settings, and never overwrite a damaged file until Save is chosen.
            recovered = true;
            return new();
        }
    }

    public void Save()
    {
        Validate();
        Directory.CreateDirectory(DirectoryPath);
        var temp = Path.Combine(DirectoryPath, "settings." + Guid.NewGuid().ToString("N") + ".tmp");
        try
        {
            File.WriteAllText(temp, JsonSerializer.Serialize(this, new JsonSerializerOptions { WriteIndented = true }), new UTF8Encoding(false));
            File.Move(temp, FilePath, true);
        }
        finally { if (File.Exists(temp)) File.Delete(temp); }
    }

    public void Validate()
    {
        if (InterfaceLanguage is not ("zh-Hant" or "en") || !LanguageIds.Contains(WritingLanguage) ||
            CustomLanguage is null || Vocabulary is null || LiveModel is null || CleanupModel is null ||
            Encoding.UTF8.GetByteCount(CustomLanguage) > 1_000 || Encoding.UTF8.GetByteCount(Vocabulary) > 16_000)
            throw new ArgumentException("Invalid settings / 設定格式不正確。");
        if (!System.Text.RegularExpressions.Regex.IsMatch(LiveModel, @"\Agemini-[A-Za-z0-9][A-Za-z0-9.-]{0,99}\z") ||
            !System.Text.RegularExpressions.Regex.IsMatch(CleanupModel, @"\Agemini-[A-Za-z0-9][A-Za-z0-9.-]{0,99}\z"))
            throw new ArgumentException("Model IDs must begin with gemini- / 模型名稱必須以 gemini- 開頭。");
        if (!ShortcutRecorderDialog.IsValid(ShortcutModifiers, ShortcutKey))
            throw new ArgumentException("Choose Ctrl, Alt or Shift with a key, or F1–F24 / 請選擇組合鍵或 F1–F24。");
        // Pure local validation only. This placeholder is never stored or sent to Google.
        GeminiLiveSession.ValidateConfiguration("local-settings-validation", Options);
    }

    public DictationOptions Options => new()
    {
        LiveModel = LiveModel.Trim(), CleanupModel = CleanupModel.Trim(), Vocabulary = Vocabulary, Polish = Polish,
        LanguageHint = WritingLanguage switch
        {
            "zh-Hant" => "Traditional Chinese (Taiwan) character forms and punctuation. Preserve all spoken languages; do not translate.",
            "zh-Hans" => "Simplified Chinese character forms and punctuation. Preserve all spoken languages; do not translate.",
            "en" => "English spelling and punctuation where English is spoken. Preserve other languages; do not translate.",
            "ja" => "Japanese spelling and punctuation where Japanese is spoken. Preserve other languages; do not translate.",
            "ko" => "Korean spelling and punctuation where Korean is spoken. Preserve other languages; do not translate.",
            "custom" when !string.IsNullOrWhiteSpace(CustomLanguage) => CustomLanguage,
            _ => "Preserve the original character forms and all spoken languages. Do not translate."
        }
    };

    public string ShortcutName => ShortcutRecorderDialog.Format(ShortcutModifiers, ShortcutKey);
}
