using System.Text;
using System.Text.Json;
using System.Text.RegularExpressions;

namespace OpenInsert.Core;

internal static partial class GeminiProtocol
{
    internal const int MaximumMessageBytes = 262144;
    internal const int MaximumTranscriptBytes = 64000;
    internal const int MaximumResponseBytes = 1000000;
    internal static readonly Uri Endpoint = new("wss://generativelanguage.googleapis.com/ws/google.ai.generativelanguage.v1beta.GenerativeService.BidiGenerateContent");
    internal const string ActivityStart = "{\"realtimeInput\":{\"activityStart\":{}}}";
    internal const string ActivityEnd = "{\"realtimeInput\":{\"activityEnd\":{}}}";

    [GeneratedRegex(@"\Agemini-[A-Za-z0-9][A-Za-z0-9.-]{0,99}\z", RegexOptions.CultureInvariant)]
    private static partial Regex ModelPattern();

    internal static string ValidateModel(string model)
    {
        if (model is null || !ModelPattern().IsMatch(model))
            throw new GeminiException("Use a Gemini model ID without a URL, spaces or models/ prefix.");
        return model;
    }

    internal static void ValidateOptions(DictationOptions options)
    {
        if (options.LanguageHint is null || options.Vocabulary is null ||
            Encoding.UTF8.GetByteCount(options.LanguageHint) > 1000 || Encoding.UTF8.GetByteCount(options.Vocabulary) > 16000)
            throw new GeminiException("Shorten the language preference or custom vocabulary in Settings.");
        ValidateText(options.LanguageHint);
        ValidateText(options.Vocabulary);
    }

    internal static string Setup(DictationOptions options)
    {
        ValidateOptions(options);
        var model = ValidateModel(options.LiveModel);
        var vocabulary = options.Vocabulary.Split(['\r', '\n', ','], StringSplitOptions.TrimEntries | StringSplitOptions.RemoveEmptyEntries);
        if (vocabulary.Length > 1000 || vocabulary.Any(v => Encoding.UTF8.GetByteCount(v) > 512))
            throw new GeminiException("Custom vocabulary supports at most 1,000 terms, each at most 512 UTF-8 bytes.");
        // LanguageHint describes orthography, never a restriction on languages spoken.
        return JsonSerializer.Serialize(new
        {
            setup = new
            {
                model = "models/" + model,
                generationConfig = new { responseModalities = new[] { "TEXT" } },
                inputAudioTranscription = new { mode = "VERBATIM", languageCodes = Array.Empty<string>(), customVocabulary = vocabulary },
                realtimeInputConfig = new { automaticActivityDetection = new { disabled = true } }
            }
        });
    }

    internal static string Audio(ReadOnlyMemory<byte> bytes) => JsonSerializer.Serialize(new
    {
        realtimeInput = new { audio = new { mimeType = "audio/pcm;rate=16000", data = Convert.ToBase64String(bytes.Span) } }
    });

    internal static void ValidateText(string text)
    {
        if (text.Any(c => (c < 32 && c is not '\t' and not '\r' and not '\n') || c == 127))
            throw GeminiException.InvalidResponse();
    }

    internal static JsonElement Object(JsonElement value)
    {
        if (value.ValueKind != JsonValueKind.Object) throw GeminiException.InvalidResponse();
        return value;
    }

    internal static bool Flag(JsonElement value, string property)
    {
        if (!value.TryGetProperty(property, out var flag)) return false;
        return flag.ValueKind switch
        {
            JsonValueKind.True => true,
            JsonValueKind.False => false,
            _ => throw GeminiException.InvalidResponse()
        };
    }
}

internal sealed record LiveEvent(bool SetupComplete, string? FinalText, string? InterimText,
    bool TurnComplete, bool Interrupted, bool Rejected, bool GoAway)
{
    internal static LiveEvent Parse(ReadOnlyMemory<byte> bytes)
    {
        if (bytes.Length > GeminiProtocol.MaximumMessageBytes) throw GeminiException.Oversized();
        try
        {
            using var document = JsonDocument.Parse(bytes);
            var root = GeminiProtocol.Object(document.RootElement);
            var setup = root.TryGetProperty("setupComplete", out var setupValue);
            if (setup) GeminiProtocol.Object(setupValue);
            string? final = null, interim = null;
            bool turn = false, interrupted = false;
            if (root.TryGetProperty("serverContent", out var content))
            {
                GeminiProtocol.Object(content);
                final = Text(content, "inputTranscription");
                interim = Text(content, "interimInputTranscription");
                turn = GeminiProtocol.Flag(content, "turnComplete");
                interrupted = GeminiProtocol.Flag(content, "interrupted");
            }
            return new(setup, final, interim, turn, interrupted,
                root.TryGetProperty("error", out _) || root.TryGetProperty("code", out _) || root.TryGetProperty("toolCall", out _),
                root.TryGetProperty("goAway", out _));
        }
        catch (JsonException) { throw GeminiException.InvalidResponse(); }
    }

    private static string? Text(JsonElement content, string field)
    {
        if (!content.TryGetProperty(field, out var obj)) return null;
        GeminiProtocol.Object(obj);
        // Metadata-only finished=true does not commit or clear an unresolved interim.
        if (!obj.TryGetProperty("text", out var value)) return null;
        if (value.ValueKind != JsonValueKind.String) throw GeminiException.InvalidResponse();
        return value.GetString();
    }
}

internal sealed class LiveTranscript
{
    internal string Committed { get; private set; } = "";
    internal string Interim { get; private set; } = "";
    internal string Preview => Committed + Interim;
    internal bool HasInterim => !string.IsNullOrWhiteSpace(Interim);

    internal bool Consume(LiveEvent message)
    {
        var old = Preview;
        if (message.FinalText is { } final)
        {
            GeminiProtocol.ValidateText(final);
            Committed += final;
            Interim = "";
        }
        if (message.InterimText is { } interim)
        {
            GeminiProtocol.ValidateText(interim);
            Interim = interim;
        }
        if (Encoding.UTF8.GetByteCount(Committed) + Encoding.UTF8.GetByteCount(Interim) > GeminiProtocol.MaximumTranscriptBytes)
            throw GeminiException.Oversized();
        return old != Preview;
    }
}
