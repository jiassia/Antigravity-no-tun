using System;
using System.IO;
using System.Net.WebSockets;
using System.Text;
using System.Text.RegularExpressions;
using System.Threading;

namespace AgyProxy
{
    public static class GuiSessionTransport
    {
        public static string Request(string address, string request, int timeout)
        {
            Uri uri = new Uri(address);
            if (uri.Scheme != "ws" || !uri.IsLoopback)
                throw new InvalidOperationException("Only the local application debugger is supported.");
            using (var cancel = new CancellationTokenSource(timeout))
            using (var socket = new ClientWebSocket())
            {
                socket.ConnectAsync(uri, cancel.Token).GetAwaiter().GetResult();
                byte[] data = Encoding.UTF8.GetBytes(request);
                socket.SendAsync(new ArraySegment<byte>(data), WebSocketMessageType.Text, true,
                    cancel.Token).GetAwaiter().GetResult();
                byte[] buffer = new byte[16384];
                while (true)
                {
                    using (var output = new MemoryStream())
                    {
                        WebSocketReceiveResult part;
                        do
                        {
                            part = socket.ReceiveAsync(new ArraySegment<byte>(buffer), cancel.Token)
                                .GetAwaiter().GetResult();
                            if (part.MessageType == WebSocketMessageType.Close)
                                throw new IOException("The application debugger closed the connection.");
                            output.Write(buffer, 0, part.Count);
                            if (output.Length > 16777216) throw new IOException("Save response exceeds 16 MB.");
                        } while (!part.EndOfMessage);
                        string result = Encoding.UTF8.GetString(output.ToArray());
                        if (Regex.IsMatch(result, "^\\s*\\{\\s*\"id\"\\s*:\\s*1\\s*[,}]"))
                            return result;
                    }
                }
            }
        }
    }
}
