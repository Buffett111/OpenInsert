using System.Net.WebSockets;
using System.Text;

namespace OpenInsert.Core;

internal interface ILiveTransport : IDisposable
{
    Task ConnectAsync(string apiKey, CancellationToken cancellationToken);
    Task SendAsync(string message, CancellationToken cancellationToken);
    Task<ReadOnlyMemory<byte>> ReceiveAsync(CancellationToken cancellationToken);
    void Abort();
}

internal sealed class WebSocketLiveTransport : ILiveTransport
{
    private readonly ClientWebSocket socket = new();
    // Supplying this invoker prevents ClientWebSocket's default redirect-following handshake.
    private readonly HttpMessageInvoker invoker = new(new SocketsHttpHandler
    {
        AllowAutoRedirect = false,
        UseCookies = false,
        ConnectTimeout = TimeSpan.FromSeconds(20)
    });

    public Task ConnectAsync(string apiKey, CancellationToken cancellationToken)
    {
        socket.Options.SetRequestHeader("x-goog-api-key", GeminiApiKey.Validate(apiKey));
        socket.Options.SetRequestHeader("Cache-Control", "no-store");
        socket.Options.KeepAliveInterval = TimeSpan.FromSeconds(20);
        return socket.ConnectAsync(GeminiProtocol.Endpoint, invoker, cancellationToken);
    }

    public Task SendAsync(string message, CancellationToken cancellationToken) =>
        socket.SendAsync(Encoding.UTF8.GetBytes(message).AsMemory(), WebSocketMessageType.Text, true, cancellationToken).AsTask();

    public async Task<ReadOnlyMemory<byte>> ReceiveAsync(CancellationToken cancellationToken)
    {
        using var message = new MemoryStream();
        var buffer = new byte[8192];
        ValueWebSocketReceiveResult part;
        do
        {
            part = await socket.ReceiveAsync(buffer.AsMemory(), cancellationToken).ConfigureAwait(false);
            if (part.MessageType == WebSocketMessageType.Close) throw GeminiException.Network();
            if (message.Length + part.Count > GeminiProtocol.MaximumMessageBytes) throw GeminiException.Oversized();
            message.Write(buffer, 0, part.Count);
        } while (!part.EndOfMessage);
        return message.ToArray();
    }

    public void Abort() => socket.Abort();
    public void Dispose() { socket.Dispose(); invoker.Dispose(); }
}
