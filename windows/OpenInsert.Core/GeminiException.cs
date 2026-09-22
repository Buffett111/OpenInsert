namespace OpenInsert.Core;

/// <summary>Messages never include remote bodies, transcripts, credentials or transport URLs.</summary>
public sealed class GeminiException(string message, bool isTransient = false) : Exception(message)
{
    public bool IsTransient { get; } = isTransient;
    internal static GeminiException InvalidResponse() => new("Gemini returned an unexpected response. Nothing was inserted.");
    internal static GeminiException Oversized() => new("The Gemini response exceeded its size limit. Nothing was inserted.");
    internal static GeminiException Empty() => new("No intelligible speech was returned. Nothing was inserted.");
    internal static GeminiException Network() => new("The Gemini connection failed. Check your connection and try again.", true);
    internal static GeminiException State() => new("The dictation session is not ready. Start a new recording.");
    internal static GeminiException FinalTimeout() => new("Could not confirm the final transcript within 20 seconds. Nothing was inserted.", true);
    internal static GeminiException CleanupTimeout() => new("Gemini text cleanup timed out.", true);
    internal static GeminiException Rejected() => new("Gemini rejected the request. Check your API key and model access.");
    internal static Exception Redact(Exception exception) => exception switch
    {
        GeminiException => exception,
        OperationCanceledException => new OperationCanceledException(),
        _ => Network()
    };
}
