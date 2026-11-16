using System;
using System.Collections.Generic;
using System.Globalization;
using System.IO;
using System.Net;
using System.Net.Sockets;
using System.Text;
using System.Threading;
using System.Threading.Tasks;

namespace Antigravity.Proxy
{
    public static class SocksBridge
    {
        private const int MaxHeaderBytes = 32768;
        private const int SetupTimeoutMs = 15000;
        private static readonly Encoding HeaderEncoding = Encoding.GetEncoding(28591);

        // This method stays in the foreground of its own PowerShell process.
        // Its caller can start that process detached from the launcher.
        public static void Run(int upstreamPort, int listenPort)
        {
            if (upstreamPort < 1 || upstreamPort > 65535 || listenPort < 1 || listenPort > 65535)
                throw new ArgumentOutOfRangeException("port");
            if (upstreamPort == listenPort)
                throw new ArgumentException("The listen and upstream ports must differ.");

            TcpListener listener = new TcpListener(IPAddress.Loopback, listenPort);
            listener.ExclusiveAddressUse = true;
            listener.Start();

            while (true)
            {
                try
                {
                    TcpClient client = listener.AcceptTcpClient();
                    ProcessClient(client, upstreamPort);
                }
                catch (SocketException)
                {
                    // A failed accept must not terminate the listener or spin.
                    Thread.Sleep(250);
                }
                catch (IOException)
                {
                    Thread.Sleep(250);
                }
                catch (Exception)
                {
                    Thread.Sleep(250);
                }
            }
        }

        private sealed class HttpError : Exception
        {
            public readonly int Status;
            public readonly string Reason;

            public HttpError(int status, string reason) : base(reason)
            {
                Status = status;
                Reason = reason;
            }
        }

        private sealed class Request
        {
            public bool IsConnect;
            public string Host;
            public int Port;
            public byte[] ForwardHeader;
            public byte[] Remainder;
        }

        private static async void ProcessClient(TcpClient client, int upstreamPort)
        {
            TcpClient upstream = null;
            bool responseStarted = false;
            int errorStatus = 0;
            string errorReason = null;
            try
            {
                try
                {
                    IPEndPoint peer = client.Client.RemoteEndPoint as IPEndPoint;
                    if (peer == null || !IPAddress.IsLoopback(peer.Address))
                        return;

                    client.NoDelay = true;
                    NetworkStream clientStream = client.GetStream();
                    Request request = await ReadRequest(clientStream).ConfigureAwait(false);

                    upstream = new TcpClient(AddressFamily.InterNetwork);
                    upstream.NoDelay = true;
                    Task connection = upstream.ConnectAsync(IPAddress.Loopback, upstreamPort);
                    await WithTimeout(connection).ConfigureAwait(false);
                    NetworkStream upstreamStream = upstream.GetStream();
                    await ConnectSocks(upstreamStream, request.Host, request.Port).ConfigureAwait(false);

                    if (request.IsConnect)
                    {
                        byte[] established = Encoding.ASCII.GetBytes("HTTP/1.1 200 Connection Established\r\n\r\n");
                        await clientStream.WriteAsync(established, 0, established.Length).ConfigureAwait(false);
                        responseStarted = true;
                    }
                    else
                    {
                        await upstreamStream.WriteAsync(request.ForwardHeader, 0, request.ForwardHeader.Length).ConfigureAwait(false);
                        responseStarted = true;
                    }

                    if (request.Remainder.Length != 0)
                        await upstreamStream.WriteAsync(request.Remainder, 0, request.Remainder.Length).ConfigureAwait(false);

                    Task towardServer = Pump(clientStream, upstreamStream, client, upstream);
                    Task towardClient = Pump(upstreamStream, clientStream, upstream, client);
                    await Task.WhenAll(towardServer, towardClient).ConfigureAwait(false);
                }
                catch (HttpError error)
                {
                    errorStatus = error.Status;
                    errorReason = error.Reason;
                }
                catch (TimeoutException)
                {
                    errorStatus = 504;
                    errorReason = "Gateway Timeout";
                }
                catch (Exception)
                {
                    errorStatus = 502;
                    errorReason = "Bad Gateway";
                }
                if (!responseStarted && errorStatus != 0)
                    await SendError(client, errorStatus, errorReason).ConfigureAwait(false);
            }
            finally
            {
                if (upstream != null) upstream.Close();
                client.Close();
            }
        }

        private static async Task WithTimeout(Task task)
        {
            if (await Task.WhenAny(task, Task.Delay(SetupTimeoutMs)).ConfigureAwait(false) != task)
                throw new TimeoutException();
            await task.ConfigureAwait(false);
        }

        private static async Task<int> ReadWithTimeout(Stream stream, byte[] buffer, int offset, int count)
        {
            Task<int> task = stream.ReadAsync(buffer, offset, count);
            if (await Task.WhenAny(task, Task.Delay(SetupTimeoutMs)).ConfigureAwait(false) != task)
                throw new TimeoutException();
            return await task.ConfigureAwait(false);
        }

        private static async Task<Request> ReadRequest(NetworkStream stream)
        {
            MemoryStream data = new MemoryStream();
            byte[] buffer = new byte[4096];
            int end = -1;
            int searched = 0;
            while (end < 0)
            {
                int count = await ReadWithTimeout(stream, buffer, 0, buffer.Length).ConfigureAwait(false);
                if (count == 0) throw new HttpError(400, "Bad Request");
                data.Write(buffer, 0, count);
                byte[] received = data.GetBuffer();
                int length = (int)data.Length;
                for (int i = Math.Max(0, searched - 3); i <= length - 4; i++)
                {
                    if (received[i] == 13 && received[i + 1] == 10 && received[i + 2] == 13 && received[i + 3] == 10)
                    {
                        end = i + 4;
                        break;
                    }
                }
                if (end > MaxHeaderBytes || (end < 0 && length > MaxHeaderBytes))
                    throw new HttpError(431, "Request Header Fields Too Large");
                searched = length;
            }

            byte[] all = data.ToArray();
            string header = HeaderEncoding.GetString(all, 0, end);
            byte[] remainder = new byte[all.Length - end];
            Buffer.BlockCopy(all, end, remainder, 0, remainder.Length);
            return ParseRequest(header, remainder);
        }

        private static Request ParseRequest(string header, byte[] remainder)
        {
            string[] lines = header.Split(new[] { "\r\n" }, StringSplitOptions.None);
            string[] parts = lines[0].Split(' ');
            if (parts.Length != 3 || !IsToken(parts[0]) || parts[1].Length == 0)
                throw new HttpError(400, "Bad Request");
            if (parts[2] != "HTTP/1.1" && parts[2] != "HTTP/1.0")
                throw new HttpError(505, "HTTP Version Not Supported");

            List<string> headers = new List<string>();
            string hostHeader = null;
            for (int i = 1; i < lines.Length - 2; i++)
            {
                string line = lines[i];
                int colon = line.IndexOf(':');
                if (colon <= 0 || !IsToken(line.Substring(0, colon)))
                    throw new HttpError(400, "Bad Request");
                string name = line.Substring(0, colon);
                string value = line.Substring(colon + 1).Trim();
                foreach (char c in value)
                    if ((c < 32 && c != '\t') || c == 127) throw new HttpError(400, "Bad Request");
                if (name.Equals("Host", StringComparison.OrdinalIgnoreCase))
                {
                    if (hostHeader != null) throw new HttpError(400, "Bad Request");
                    hostHeader = value;
                }
                if (!name.Equals("Proxy-Authorization", StringComparison.OrdinalIgnoreCase) &&
                    !name.Equals("Proxy-Connection", StringComparison.OrdinalIgnoreCase) &&
                    !name.Equals("Connection", StringComparison.OrdinalIgnoreCase) &&
                    !name.Equals("Keep-Alive", StringComparison.OrdinalIgnoreCase))
                    headers.Add(line);
            }

            Request request = new Request();
            request.Remainder = remainder;
            request.IsConnect = parts[0].Equals("CONNECT", StringComparison.OrdinalIgnoreCase);
            if (request.IsConnect)
            {
                ParseAuthority(parts[1], true, out request.Host, out request.Port);
                return request;
            }

            string path;
            Uri uri;
            if (parts[1].StartsWith("/", StringComparison.Ordinal))
            {
                if (hostHeader == null) throw new HttpError(400, "Bad Request");
                ParseAuthority(hostHeader, false, out request.Host, out request.Port);
                path = parts[1];
            }
            else if (Uri.TryCreate(parts[1], UriKind.Absolute, out uri))
            {
                if (!uri.Scheme.Equals("http", StringComparison.OrdinalIgnoreCase))
                    throw new HttpError(501, "Not Implemented");
                if (uri.UserInfo.Length != 0 || uri.Fragment.Length != 0 || uri.Host.Length == 0)
                    throw new HttpError(400, "Bad Request");
                request.Host = NormalizeHost(uri);
                request.Port = uri.Port;
                path = uri.PathAndQuery;
                if (String.IsNullOrEmpty(path)) path = "/";
                if (hostHeader == null) headers.Add("Host: " + uri.Authority);
            }
            else
            {
                throw new HttpError(400, "Bad Request");
            }

            StringBuilder outgoing = new StringBuilder();
            outgoing.Append(parts[0]).Append(' ').Append(path).Append(' ').Append(parts[2]).Append("\r\n");
            foreach (string line in headers) outgoing.Append(line).Append("\r\n");
            outgoing.Append("Connection: close\r\n\r\n");
            request.ForwardHeader = HeaderEncoding.GetBytes(outgoing.ToString());
            return request;
        }

        private static bool IsToken(string value)
        {
            if (value.Length == 0) return false;
            foreach (char c in value)
            {
                if (c <= 32 || c >= 127 || "()<>@,;:\\\"/[]?={}".IndexOf(c) >= 0)
                    return false;
            }
            return true;
        }

        private static void ParseAuthority(string authority, bool requirePort, out string host, out int port)
        {
            if (authority.Length == 0 || authority.IndexOfAny(new[] { '/', '?', '#', '@', ',', '\\', ' ', '\t', '\r', '\n' }) >= 0)
                throw new HttpError(400, "Bad Request");
            int colon;
            if (authority[0] == '[')
            {
                int endBracket = authority.IndexOf(']');
                if (endBracket < 0 || (endBracket + 1 < authority.Length && authority[endBracket + 1] != ':'))
                    throw new HttpError(400, "Bad Request");
                colon = endBracket + 1 < authority.Length ? endBracket + 1 : -1;
            }
            else
            {
                colon = authority.IndexOf(':');
                if (colon >= 0 && authority.IndexOf(':', colon + 1) >= 0)
                    throw new HttpError(400, "Bad Request");
            }
            if (colon < 0 && requirePort) throw new HttpError(400, "Bad Request");
            if (colon >= 0)
            {
                string portText = authority.Substring(colon + 1);
                if (portText.Length == 0 || !Int32.TryParse(portText, NumberStyles.None, CultureInfo.InvariantCulture, out port) || port < 1 || port > 65535)
                    throw new HttpError(400, "Bad Request");
            }
            else port = 80;

            Uri uri;
            if (!Uri.TryCreate("http://" + authority + "/", UriKind.Absolute, out uri) || uri.Host.Length == 0)
                throw new HttpError(400, "Bad Request");
            host = NormalizeHost(uri);
        }

        private static string NormalizeHost(Uri uri)
        {
            string host = uri.IdnHost;
            if (host.StartsWith("[", StringComparison.Ordinal) && host.EndsWith("]", StringComparison.Ordinal))
                host = host.Substring(1, host.Length - 2);
            if (host.Length == 0) throw new HttpError(400, "Bad Request");
            return host;
        }

        private static async Task ConnectSocks(NetworkStream stream, string host, int port)
        {
            byte[] greeting = { 5, 1, 0 };
            await stream.WriteAsync(greeting, 0, greeting.Length).ConfigureAwait(false);
            byte[] reply = new byte[4];
            await ReadExactly(stream, reply, 0, 2).ConfigureAwait(false);
            if (reply[0] != 5 || reply[1] != 0) throw new IOException("SOCKS5 anonymous authentication was rejected.");

            byte[] address;
            byte addressType;
            IPAddress ip;
            if (IPAddress.TryParse(host, out ip))
            {
                address = ip.GetAddressBytes();
                addressType = ip.AddressFamily == AddressFamily.InterNetwork ? (byte)1 : (byte)4;
            }
            else
            {
                byte[] domain = Encoding.ASCII.GetBytes(host);
                if (domain.Length == 0 || domain.Length > 255) throw new IOException("Invalid SOCKS domain.");
                address = new byte[domain.Length + 1];
                address[0] = (byte)domain.Length;
                Buffer.BlockCopy(domain, 0, address, 1, domain.Length);
                addressType = 3;
            }
            byte[] request = new byte[4 + address.Length + 2];
            request[0] = 5;
            request[1] = 1;
            request[2] = 0;
            request[3] = addressType;
            Buffer.BlockCopy(address, 0, request, 4, address.Length);
            request[request.Length - 2] = (byte)(port >> 8);
            request[request.Length - 1] = (byte)port;
            await stream.WriteAsync(request, 0, request.Length).ConfigureAwait(false);

            await ReadExactly(stream, reply, 0, 4).ConfigureAwait(false);
            if (reply[0] != 5 || reply[1] != 0 || reply[2] != 0) throw new IOException("SOCKS5 connection failed.");
            int addressLength;
            if (reply[3] == 1) addressLength = 4;
            else if (reply[3] == 4) addressLength = 16;
            else if (reply[3] == 3)
            {
                await ReadExactly(stream, reply, 0, 1).ConfigureAwait(false);
                addressLength = reply[0];
            }
            else throw new IOException("Invalid SOCKS5 address type.");
            byte[] tail = new byte[addressLength + 2];
            await ReadExactly(stream, tail, 0, tail.Length).ConfigureAwait(false);
        }

        private static async Task ReadExactly(Stream stream, byte[] buffer, int offset, int count)
        {
            while (count > 0)
            {
                int read = await ReadWithTimeout(stream, buffer, offset, count).ConfigureAwait(false);
                if (read == 0) throw new EndOfStreamException();
                offset += read;
                count -= read;
            }
        }

        private static async Task Pump(Stream source, Stream destination, TcpClient sourceClient, TcpClient destinationClient)
        {
            try
            {
                await source.CopyToAsync(destination).ConfigureAwait(false);
                try { destinationClient.Client.Shutdown(SocketShutdown.Send); }
                catch (SocketException) { }
                catch (ObjectDisposedException) { }
            }
            catch (Exception)
            {
                sourceClient.Close();
                destinationClient.Close();
            }
        }

        private static async Task SendError(TcpClient client, int status, string reason)
        {
            try
            {
                byte[] response = Encoding.ASCII.GetBytes("HTTP/1.1 " + status + " " + reason + "\r\nConnection: close\r\nContent-Length: 0\r\n\r\n");
                await client.GetStream().WriteAsync(response, 0, response.Length).ConfigureAwait(false);
            }
            catch (Exception) { }
        }
    }
}
