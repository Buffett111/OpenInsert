namespace OpenInsert.Core;

public sealed record DictationOptions
{
    public const string DefaultLanguageHint = "Traditional Chinese (Taiwan) character forms and punctuation. Preserve all languages actually spoken, including mixed Chinese and English. Do not translate.";
    public string LiveModel { get; init; } = "gemini-3.5-transcribe-live";
    public string CleanupModel { get; init; } = "gemini-3.5-flash-lite";
    public string LanguageHint { get; init; } = DefaultLanguageHint;
    public string Vocabulary { get; init; } = "";
    public bool Polish { get; init; } = true;
}
