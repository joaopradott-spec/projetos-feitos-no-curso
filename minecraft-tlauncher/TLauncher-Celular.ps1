$ErrorActionPreference = "Stop"
$Host.UI.RawUI.WindowTitle = "TLauncher pelo celular"

Write-Host "=== TLauncher pelo celular ===" -ForegroundColor Cyan
Write-Host "Sem admin. So o trafego deste launcher passa pelo roteamento USB." -ForegroundColor DarkGray
Write-Host ""

# 1) Descobre o IP do tether USB.
$phone = Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue |
    Where-Object {
        $_.AddressState -eq "Preferred" -and
        $_.IPAddress -like "192.168.42.*"
    } |
    Select-Object -First 1

if (-not $phone) {
    Write-Host "Nao encontrei o roteamento USB do celular (192.168.42.x)." -ForegroundColor Red
    Write-Host "Conecte/ative o roteamento USB e abra este launcher novamente."
    Read-Host "Pressione ENTER para sair"
    exit 1
}

$bindIP = $phone.IPAddress
Write-Host "Celular detectado: $($phone.InterfaceAlias) - $bindIP" -ForegroundColor Green

# Descobre a rota padrao que NAO e o celular: normalmente a rede do curso.
$schoolRoute = Get-NetRoute -AddressFamily IPv4 -DestinationPrefix "0.0.0.0/0" -ErrorAction SilentlyContinue |
    Where-Object { $_.InterfaceIndex -ne $phone.InterfaceIndex } |
    Sort-Object RouteMetric |
    Select-Object -First 1

$schoolIP = $null
if ($schoolRoute) {
    $schoolAddr = Get-NetIPAddress -AddressFamily IPv4 -InterfaceIndex $schoolRoute.InterfaceIndex -ErrorAction SilentlyContinue |
        Where-Object {
            $_.AddressState -eq "Preferred" -and
            $_.IPAddress -notlike "169.254.*" -and
            $_.IPAddress -ne "127.0.0.1"
        } |
        Select-Object -First 1

    if ($schoolAddr) {
        $schoolIP = $schoolAddr.IPAddress
        Write-Host "Rede do curso: $($schoolAddr.InterfaceAlias) - $schoolIP" -ForegroundColor Green
    }
}

if (-not $schoolIP) {
    Write-Host "Aviso: nao encontrei outra rota de Internet. O modo economia nao podera usar a rede do curso." -ForegroundColor Yellow
}

# Modo preferencia:
# tenta SEMPRE a rede do curso primeiro e usa o celular apenas quando o host
# realmente falhar/bloquear pela rede do curso.
Write-Host "Modo v11: HTTP + SOCKS5, escola primeiro em TODA a JVM." -ForegroundColor Cyan

# 2) Confirma que o TLauncher e acessivel diretamente pelo celular.
Write-Host "Testando acesso ao site pelo celular..."
$testDirect = Join-Path $env:TEMP "tl-direct-test.tmp"
Remove-Item $testDirect -Force -ErrorAction SilentlyContinue
& curl.exe -4 --interface $bindIP --connect-timeout 10 -L -sS --output $testDirect "https://tlauncher.org/"
$directExit = $LASTEXITCODE
Remove-Item $testDirect -Force -ErrorAction SilentlyContinue
if ($directExit -ne 0) {
    Write-Host "O celular foi detectado, mas nao conseguiu acessar tlauncher.org." -ForegroundColor Red
    Read-Host "Pressione ENTER para sair"
    exit 2
}

# 3) Proxy HTTP/HTTPS local preso ao IP do celular.
$code = @'
using System;
using System.IO;
using System.Net;
using System.Net.Sockets;
using System.Net.Security;
using System.Text;
using System.Threading;
using System.Collections.Generic;

public static class TLBoundProxy
{
    static string phoneIp;
    static string schoolIp;
    static long mobileBudgetBytes;
    static long phoneBytes;
    static long schoolBytes;
    static TcpListener listener;
    static volatile bool running;

    static readonly object cacheLock = new object();
    static readonly Dictionary<string, bool> routeCache =
        new Dictionary<string, bool>(StringComparer.OrdinalIgnoreCase);

    // Hosts conhecidos por carregar arquivos grandes. Em modo economia eles
    // NUNCA caem no celular: ou usam a rede do curso, ou falham.
    static readonly string[] schoolOnlyBulkHosts = new string[] {
        "resources.download.minecraft.net",
        "libraries.minecraft.net",
        "piston-data.mojang.com",
        "launcher.mojang.com",
        "resource.fastrepo.org",
        "repo.fastrepo.org",
        "repo.tl.vg",
        "mediafilez.forgecdn.net",
        "edge.forgecdn.net",
        "cdn.modrinth.com",
        "maven.minecraftforge.net",
        "files.minecraftforge.net",
        "maven.fabricmc.net"
    };

    public static bool TryStart(string phone, string school, int port, long budgetBytes)
    {
        try
        {
            phoneIp = phone;
            schoolIp = school;
            mobileBudgetBytes = budgetBytes;
            phoneBytes = 0;
            schoolBytes = 0;

            listener = new TcpListener(IPAddress.Loopback, port);
            listener.Start();
            running = true;

            Thread t = new Thread(AcceptLoop);
            t.IsBackground = true;
            t.Start();
            return true;
        }
        catch
        {
            try { if (listener != null) listener.Stop(); } catch {}
            listener = null;
            return false;
        }
    }

    public static void Stop()
    {
        running = false;
        try { if (listener != null) listener.Stop(); } catch {}
    }

    public static long GetPhoneBytes() { return Interlocked.Read(ref phoneBytes); }
    public static long GetSchoolBytes() { return Interlocked.Read(ref schoolBytes); }

    static void AcceptLoop()
    {
        while (running)
        {
            try
            {
                TcpClient c = listener.AcceptTcpClient();
                Thread t = new Thread(() => Handle(c));
                t.IsBackground = true;
                t.Start();
            }
            catch
            {
                if (!running) return;
            }
        }
    }

    static bool EndsWithHost(string host, string wanted)
    {
        return host.Equals(wanted, StringComparison.OrdinalIgnoreCase) ||
               host.EndsWith("." + wanted, StringComparison.OrdinalIgnoreCase);
    }

    static bool IsSchoolOnlyBulk(string host)
    {
        // v9: nenhum host e proibido de usar o celular.
        // A escola continua tendo prioridade, mas o celular pode ser fallback.
        return false;
    }

    static Socket ConnectBound(string host, int port, string sourceIp, int timeoutMs)
    {
        Exception last = null;

        foreach (IPAddress addr in Dns.GetHostAddresses(host))
        {
            if (addr.AddressFamily != AddressFamily.InterNetwork)
                continue;

            Socket s = null;
            try
            {
                s = new Socket(AddressFamily.InterNetwork, SocketType.Stream, ProtocolType.Tcp);
                s.Bind(new IPEndPoint(IPAddress.Parse(sourceIp), 0));

                IAsyncResult ar = s.BeginConnect(addr, port, null, null);
                if (!ar.AsyncWaitHandle.WaitOne(timeoutMs, false))
                {
                    try { s.Close(); } catch {}
                    throw new TimeoutException("Connect timeout");
                }
                s.EndConnect(ar);

                s.ReceiveTimeout = timeoutMs;
                s.SendTimeout = timeoutMs;
                return s;
            }
            catch (Exception ex)
            {
                last = ex;
                try { if (s != null) s.Close(); } catch {}
            }
        }

        throw last ?? new Exception("Nenhum IPv4 disponivel para " + host);
    }

    // Teste mais forte: abre TLS PELA ESCOLA e envia um HEAD real.
    // A v9 so testava o handshake TLS; alguns filtros deixam o TLS subir e
    // resetam quando chega a requisicao HTTP. Isso fazia um host ser marcado
    // erroneamente como "ESCOLA".
    static bool ProbeSchoolTls(string host, int port)
    {
        if (String.IsNullOrEmpty(schoolIp))
            return false;

        Socket s = null;
        NetworkStream ns = null;
        SslStream ssl = null;

        try
        {
            s = ConnectBound(host, port, schoolIp, 3000);
            ns = new NetworkStream(s, true);
            ns.ReadTimeout = 3500;
            ns.WriteTimeout = 3500;

            ssl = new SslStream(
                ns,
                false,
                delegate { return true; }
            );

            IAsyncResult ar = ssl.BeginAuthenticateAsClient(host, null, null);
            if (!ar.AsyncWaitHandle.WaitOne(3500, false))
            {
                try { ssl.Close(); } catch {}
                return false;
            }

            ssl.EndAuthenticateAsClient(ar);

            string req =
                "HEAD / HTTP/1.1\r\n" +
                "Host: " + host + "\r\n" +
                "User-Agent: Mozilla/5.0\r\n" +
                "Connection: close\r\n\r\n";

            byte[] rb = Encoding.ASCII.GetBytes(req);
            ssl.Write(rb, 0, rb.Length);
            ssl.Flush();

            byte[] buf = new byte[32];
            int n = ssl.Read(buf, 0, buf.Length);

            if (n <= 0)
                return false;

            string first = Encoding.ASCII.GetString(buf, 0, n);
            return first.StartsWith("HTTP/", StringComparison.OrdinalIgnoreCase);
        }
        catch
        {
            return false;
        }
        finally
        {
            try { if (ssl != null) ssl.Close(); } catch {}
            try { if (ns != null) ns.Close(); } catch {}
            try { if (s != null) s.Close(); } catch {}
        }
    }

    static bool ProbeSchoolTcp(string host, int port)
    {
        if (String.IsNullOrEmpty(schoolIp))
            return false;

        Socket s = null;
        try
        {
            s = ConnectBound(host, port, schoolIp, 2500);
            return true;
        }
        catch
        {
            return false;
        }
        finally
        {
            try { if (s != null) s.Close(); } catch {}
        }
    }

    static void MarkPhoneAfterSchoolReset(string host, int port)
    {
        string key = host + ":" + port.ToString();

        lock (cacheLock)
            routeCache[key] = true;

        Console.WriteLine("[FALLBACK -> CELULAR] " + key + " (reset/falha durante uso pela escola)");
    }

    static bool ChoosePhone(string host, int port)
    {
        // Arquivo grande conhecido: nunca gasta dados moveis.
        if (IsSchoolOnlyBulk(host))
        {
            Console.WriteLine("[ESCOLA/SEM-FALLBACK] " + host);
            return false;
        }

        string key = host + ":" + port.ToString();
        lock (cacheLock)
        {
            bool cached;
            if (routeCache.TryGetValue(key, out cached))
                return cached;
        }

        bool schoolWorks = (port == 443)
            ? ProbeSchoolTls(host, port)
            : ProbeSchoolTcp(host, port);

        bool usePhone = !schoolWorks;

        lock (cacheLock)
            routeCache[key] = usePhone;

        Console.WriteLine(
            (usePhone ? "[CELULAR] " : "[ESCOLA] ") + host
        );

        return usePhone;
    }

    static Socket ConnectForRoute(string host, int port, out bool usePhone)
    {
        usePhone = ChoosePhone(host, port);

        if (!usePhone)
        {
            if (String.IsNullOrEmpty(schoolIp))
                throw new Exception("Rede do curso indisponivel");

            // Hosts grandes nao possuem fallback de celular.
            if (IsSchoolOnlyBulk(host))
                return ConnectBound(host, port, schoolIp, 5000);

            try
            {
                return ConnectBound(host, port, schoolIp, 5000);
            }
            catch
            {
                // Se a rota da escola mudou depois do probe, pode cair no celular,
                // respeitando o limite global.
                usePhone = true;
            }
        }

        return ConnectBound(host, port, phoneIp, 7000);
    }

    static void Handle(TcpClient client)
    {
        Socket remote = null;

        try
        {
            NetworkStream local = client.GetStream();
            byte[] hb = ReadHeader(local, 65536);

            if (hb == null) { client.Close(); return; }

            string header = Encoding.GetEncoding(28591).GetString(hb);
            string[] lines = header.Split(new string[] { "\r\n" }, StringSplitOptions.None);

            if (lines.Length == 0) { client.Close(); return; }

            string[] first = lines[0].Split(' ');
            if (first.Length < 2) { client.Close(); return; }

            string method = first[0];
            string target = first[1];

            if (method.Equals("CONNECT", StringComparison.OrdinalIgnoreCase))
            {
                string host;
                int port;
                ParseHostPort(target, 443, out host, out port);

                bool usePhone;
                remote = ConnectForRoute(host, port, out usePhone);
                NetworkStream internet = new NetworkStream(remote, true);

                Send(local,
                    "HTTP/1.1 200 Connection Established\r\n" +
                    "Proxy-Agent: TLSplitProxy\r\n\r\n");

                Relay(local, internet, client, usePhone, host, port);
                return;
            }

            Uri uri;
            string host2 = null;
            int port2 = 80;
            string path = target;

            if (Uri.TryCreate(target, UriKind.Absolute, out uri))
            {
                host2 = uri.Host;
                port2 = uri.IsDefaultPort
                    ? (uri.Scheme.Equals("https", StringComparison.OrdinalIgnoreCase) ? 443 : 80)
                    : uri.Port;
                path = String.IsNullOrEmpty(uri.PathAndQuery) ? "/" : uri.PathAndQuery;
            }
            else
            {
                foreach (string line in lines)
                {
                    if (line.StartsWith("Host:", StringComparison.OrdinalIgnoreCase))
                    {
                        string hv = line.Substring(5).Trim();
                        ParseHostPort(hv, 80, out host2, out port2);
                        break;
                    }
                }
            }

            if (String.IsNullOrEmpty(host2))
                throw new Exception("Host HTTP nao encontrado");

            bool usePhone2;
            remote = ConnectForRoute(host2, port2, out usePhone2);
            NetworkStream internet2 = new NetworkStream(remote, true);

            StringBuilder rewritten = new StringBuilder();
            string version = first.Length >= 3 ? first[2] : "HTTP/1.1";

            rewritten.Append(method).Append(" ").Append(path)
                     .Append(" ").Append(version).Append("\r\n");

            bool hadConnection = false;

            for (int i = 1; i < lines.Length; i++)
            {
                string line = lines[i];
                if (line.Length == 0) continue;
                if (line.StartsWith("Proxy-Connection:", StringComparison.OrdinalIgnoreCase)) continue;

                if (line.StartsWith("Connection:", StringComparison.OrdinalIgnoreCase))
                {
                    rewritten.Append("Connection: close\r\n");
                    hadConnection = true;
                    continue;
                }

                rewritten.Append(line).Append("\r\n");
            }

            if (!hadConnection)
                rewritten.Append("Connection: close\r\n");

            rewritten.Append("\r\n");

            Send(internet2, rewritten.ToString());
            Relay(local, internet2, client, usePhone2, host2, port2);
        }
        catch
        {
            try
            {
                Send(client.GetStream(),
                    "HTTP/1.1 502 Bad Gateway\r\n" +
                    "Connection: close\r\n\r\n");
            }
            catch {}

            try { client.Close(); } catch {}
            try { if (remote != null) remote.Close(); } catch {}
        }
    }

    static void ParseHostPort(string value, int defaultPort, out string host, out int port)
    {
        host = value;
        port = defaultPort;

        int colon = value.LastIndexOf(':');

        if (colon > 0 && value.IndexOf(':') == colon)
        {
            int parsed;
            if (Int32.TryParse(value.Substring(colon + 1), out parsed))
            {
                host = value.Substring(0, colon);
                port = parsed;
            }
        }
    }

    static byte[] ReadHeader(Stream s, int max)
    {
        MemoryStream ms = new MemoryStream();
        int state = 0;

        while (ms.Length < max)
        {
            int b = s.ReadByte();
            if (b < 0) return null;

            ms.WriteByte((byte)b);

            if (state == 0 && b == 13) state = 1;
            else if (state == 1 && b == 10) state = 2;
            else if (state == 2 && b == 13) state = 3;
            else if (state == 3 && b == 10) return ms.ToArray();
            else state = (b == 13) ? 1 : 0;
        }

        return null;
    }

    static void Relay(
        Stream clientToProxy,
        Stream remoteToProxy,
        TcpClient client,
        bool usePhone,
        string host,
        int port)
    {
        Thread up = new Thread(
            () => Pump(clientToProxy, remoteToProxy, false, usePhone, host, port, false)
        );

        Thread down = new Thread(
            () => Pump(remoteToProxy, clientToProxy, true, usePhone, host, port, true)
        );

        up.IsBackground = true;
        down.IsBackground = true;

        up.Start();
        down.Start();

        // Espera qualquer lado terminar. O importante e que, se o servidor
        // resetar a conexao da escola, o Pump de download marca o host para
        // celular. TLauncher normalmente tenta novamente o arquivo.
        up.Join();

        try { client.Close(); } catch {}
        try { remoteToProxy.Close(); } catch {}
    }

    static void Pump(
        Stream input,
        Stream output,
        bool countDownload,
        bool usePhone,
        string host,
        int port,
        bool remoteInput)
    {
        try
        {
            byte[] buf = new byte[65536];
            int n;

            while ((n = input.Read(buf, 0, buf.Length)) > 0)
            {
                if (countDownload)
                {
                    if (usePhone)
                        Interlocked.Add(ref phoneBytes, n);
                    else
                        Interlocked.Add(ref schoolBytes, n);
                }

                output.Write(buf, 0, n);
                output.Flush();
            }
        }
        catch
        {
            // Se o lado REMOTO derrubar/resetar um tunel que estava pela
            // escola, a proxima conexao desse host passa pelo celular.
            if (!usePhone && remoteInput)
                MarkPhoneAfterSchoolReset(host, port);
        }
    }

    static void Send(Stream s, string text)
    {
        byte[] b = Encoding.GetEncoding(28591).GetBytes(text);
        s.Write(b, 0, b.Length);
        s.Flush();
    }
}

public static class TLSocksProxy
{
    static string phoneIp;
    static string schoolIp;
    static TcpListener listener;
    static volatile bool running;
    static long phoneBytes;
    static long schoolBytes;

    static readonly object cacheLock = new object();
    static readonly Dictionary<string, bool> routeCache =
        new Dictionary<string, bool>(StringComparer.OrdinalIgnoreCase);

    public static bool TryStart(string phone, string school, int port)
    {
        try
        {
            phoneIp = phone;
            schoolIp = school;
            phoneBytes = 0;
            schoolBytes = 0;

            listener = new TcpListener(IPAddress.Loopback, port);
            listener.Start();
            running = true;

            Thread t = new Thread(AcceptLoop);
            t.IsBackground = true;
            t.Start();
            return true;
        }
        catch
        {
            try { if (listener != null) listener.Stop(); } catch {}
            listener = null;
            return false;
        }
    }

    public static void Stop()
    {
        running = false;
        try { if (listener != null) listener.Stop(); } catch {}
    }

    public static long GetPhoneBytes() { return Interlocked.Read(ref phoneBytes); }
    public static long GetSchoolBytes() { return Interlocked.Read(ref schoolBytes); }

    static void AcceptLoop()
    {
        while (running)
        {
            try
            {
                TcpClient c = listener.AcceptTcpClient();
                Thread t = new Thread(() => Handle(c));
                t.IsBackground = true;
                t.Start();
            }
            catch
            {
                if (!running) return;
            }
        }
    }

    static Socket ConnectBound(string host, int port, string sourceIp, int timeoutMs)
    {
        Exception last = null;

        foreach (IPAddress addr in Dns.GetHostAddresses(host))
        {
            if (addr.AddressFamily != AddressFamily.InterNetwork)
                continue;

            Socket s = null;
            try
            {
                s = new Socket(AddressFamily.InterNetwork, SocketType.Stream, ProtocolType.Tcp);
                s.Bind(new IPEndPoint(IPAddress.Parse(sourceIp), 0));

                IAsyncResult ar = s.BeginConnect(addr, port, null, null);
                if (!ar.AsyncWaitHandle.WaitOne(timeoutMs, false))
                {
                    try { s.Close(); } catch {}
                    throw new TimeoutException("Connect timeout");
                }

                s.EndConnect(ar);
                s.ReceiveTimeout = timeoutMs;
                s.SendTimeout = timeoutMs;
                return s;
            }
            catch (Exception ex)
            {
                last = ex;
                try { if (s != null) s.Close(); } catch {}
            }
        }

        throw last ?? new Exception("Nenhum IPv4 disponivel para " + host);
    }

    static bool LooksLikeIp(string host)
    {
        IPAddress a;
        return IPAddress.TryParse(host, out a);
    }

    static bool ProbeSchoolTls(string host, int port)
    {
        if (String.IsNullOrEmpty(schoolIp))
            return false;

        // Se o cliente SOCKS nos passou apenas um IP, nao temos o SNI real.
        // Nesse caso fazemos apenas o teste TCP.
        if (LooksLikeIp(host))
            return ProbeSchoolTcp(host, port);

        Socket s = null;
        NetworkStream ns = null;
        SslStream ssl = null;

        try
        {
            s = ConnectBound(host, port, schoolIp, 2800);
            ns = new NetworkStream(s, true);
            ns.ReadTimeout = 3200;
            ns.WriteTimeout = 3200;

            ssl = new SslStream(
                ns,
                false,
                delegate { return true; }
            );

            IAsyncResult ar = ssl.BeginAuthenticateAsClient(host, null, null);
            if (!ar.AsyncWaitHandle.WaitOne(3200, false))
                return false;

            ssl.EndAuthenticateAsClient(ar);

            string req =
                "HEAD / HTTP/1.1\r\n" +
                "Host: " + host + "\r\n" +
                "User-Agent: Mozilla/5.0\r\n" +
                "Connection: close\r\n\r\n";

            byte[] rb = Encoding.ASCII.GetBytes(req);
            ssl.Write(rb, 0, rb.Length);
            ssl.Flush();

            byte[] buf = new byte[24];
            int n = ssl.Read(buf, 0, buf.Length);

            if (n <= 0)
                return false;

            string first = Encoding.ASCII.GetString(buf, 0, n);
            return first.StartsWith("HTTP/", StringComparison.OrdinalIgnoreCase);
        }
        catch
        {
            return false;
        }
        finally
        {
            try { if (ssl != null) ssl.Close(); } catch {}
            try { if (ns != null) ns.Close(); } catch {}
            try { if (s != null) s.Close(); } catch {}
        }
    }

    static bool ProbeSchoolTcp(string host, int port)
    {
        if (String.IsNullOrEmpty(schoolIp))
            return false;

        Socket s = null;
        try
        {
            s = ConnectBound(host, port, schoolIp, 2500);
            return true;
        }
        catch
        {
            return false;
        }
        finally
        {
            try { if (s != null) s.Close(); } catch {}
        }
    }

    static bool ChoosePhone(string host, int port)
    {
        string key = host + ":" + port.ToString();

        lock (cacheLock)
        {
            bool cached;
            if (routeCache.TryGetValue(key, out cached))
                return cached;
        }

        bool schoolWorks =
            (port == 443)
            ? ProbeSchoolTls(host, port)
            : ProbeSchoolTcp(host, port);

        bool usePhone = !schoolWorks;

        lock (cacheLock)
            routeCache[key] = usePhone;

        Console.WriteLine(
            (usePhone ? "[SOCKS CELULAR] " : "[SOCKS ESCOLA] ") + key
        );

        return usePhone;
    }

    static void MarkPhone(string host, int port)
    {
        string key = host + ":" + port.ToString();

        lock (cacheLock)
            routeCache[key] = true;

        Console.WriteLine("[SOCKS FALLBACK -> CELULAR] " + key);
    }

    static Socket ConnectForRoute(string host, int port, out bool usePhone)
    {
        usePhone = ChoosePhone(host, port);

        if (!usePhone)
        {
            try
            {
                return ConnectBound(host, port, schoolIp, 5000);
            }
            catch
            {
                usePhone = true;
                MarkPhone(host, port);
            }
        }

        return ConnectBound(host, port, phoneIp, 7000);
    }

    static int ReadByteExact(Stream s)
    {
        int b = s.ReadByte();
        if (b < 0) throw new EndOfStreamException();
        return b;
    }

    static byte[] ReadExact(Stream s, int count)
    {
        byte[] b = new byte[count];
        int off = 0;

        while (off < count)
        {
            int n = s.Read(b, off, count - off);
            if (n <= 0) throw new EndOfStreamException();
            off += n;
        }

        return b;
    }

    static void Handle(TcpClient client)
    {
        Socket remote = null;

        try
        {
            NetworkStream local = client.GetStream();
            local.ReadTimeout = 10000;
            local.WriteTimeout = 10000;

            int ver = ReadByteExact(local);
            if (ver != 5) throw new Exception("SOCKS version");

            int nMethods = ReadByteExact(local);
            ReadExact(local, nMethods);

            // SOCKS5, sem autenticacao.
            local.Write(new byte[] { 5, 0 }, 0, 2);
            local.Flush();

            int reqVer = ReadByteExact(local);
            int cmd = ReadByteExact(local);
            int rsv = ReadByteExact(local);
            int atyp = ReadByteExact(local);

            if (reqVer != 5 || cmd != 1)
                throw new Exception("SOCKS CONNECT esperado");

            string host;

            if (atyp == 1)
            {
                host = new IPAddress(ReadExact(local, 4)).ToString();
            }
            else if (atyp == 3)
            {
                int len = ReadByteExact(local);
                host = Encoding.ASCII.GetString(ReadExact(local, len));
            }
            else if (atyp == 4)
            {
                // IPv6 nao e necessario neste PC; le e rejeita.
                ReadExact(local, 16);
                ReadExact(local, 2);
                local.Write(new byte[] { 5, 8, 0, 1, 0, 0, 0, 0, 0, 0 }, 0, 10);
                local.Flush();
                client.Close();
                return;
            }
            else
            {
                throw new Exception("ATYP invalido");
            }

            byte[] portBytes = ReadExact(local, 2);
            int port = (portBytes[0] << 8) | portBytes[1];

            bool usePhone;
            remote = ConnectForRoute(host, port, out usePhone);
            NetworkStream internet = new NetworkStream(remote, true);

            // SOCKS success.
            byte[] ok = new byte[] { 5, 0, 0, 1, 127, 0, 0, 1, 0, 0 };
            local.Write(ok, 0, ok.Length);
            local.Flush();

            Thread up = new Thread(
                () => Pump(local, internet, false, usePhone, host, port, false)
            );

            Thread down = new Thread(
                () => Pump(internet, local, true, usePhone, host, port, true)
            );

            up.IsBackground = true;
            down.IsBackground = true;

            up.Start();
            down.Start();

            up.Join();

            try { client.Close(); } catch {}
            try { internet.Close(); } catch {}
        }
        catch
        {
            try
            {
                NetworkStream local = client.GetStream();
                byte[] fail = new byte[] { 5, 1, 0, 1, 0, 0, 0, 0, 0, 0 };
                local.Write(fail, 0, fail.Length);
                local.Flush();
            }
            catch {}

            try { client.Close(); } catch {}
            try { if (remote != null) remote.Close(); } catch {}
        }
    }

    static void Pump(
        Stream input,
        Stream output,
        bool countDownload,
        bool usePhone,
        string host,
        int port,
        bool remoteInput)
    {
        try
        {
            byte[] buf = new byte[65536];
            int n;

            while ((n = input.Read(buf, 0, buf.Length)) > 0)
            {
                if (countDownload)
                {
                    if (usePhone)
                        Interlocked.Add(ref phoneBytes, n);
                    else
                        Interlocked.Add(ref schoolBytes, n);
                }

                output.Write(buf, 0, n);
                output.Flush();
            }
        }
        catch
        {
            if (!usePhone && remoteInput)
                MarkPhone(host, port);
        }
    }
}

'@

Add-Type -TypeDefinition $code

$proxyPort = $null
$budgetBytes = [int64]::MaxValue

foreach ($p in 18081..18120) {
    if ([TLBoundProxy]::TryStart($bindIP, $schoolIP, $p, $budgetBytes)) {
        $proxyPort = $p
        break
    }
}
if (-not $proxyPort) {
    Write-Host "Nao consegui abrir uma porta local para o proxy." -ForegroundColor Red
    Read-Host "Pressione ENTER para sair"
    exit 3
}

$proxy = "http://127.0.0.1:$proxyPort"
Write-Host "Proxy HTTP local: $proxy" -ForegroundColor Green

$socksPort = $null
foreach ($p in 19081..19120) {
    if ([TLSocksProxy]::TryStart($bindIP, $schoolIP, $p)) {
        $socksPort = $p
        break
    }
}

if (-not $socksPort) {
    Write-Host "Nao consegui abrir uma porta SOCKS local." -ForegroundColor Red
    [TLSocksProxy]::Stop()
    [TLBoundProxy]::Stop()
    Read-Host "Pressione ENTER para sair"
    exit 4
}

Write-Host "Proxy SOCKS5 local: 127.0.0.1:$socksPort" -ForegroundColor Green
Write-Host "HTTP = trafego conhecido; SOCKS = camada TCP da JVM principal." -ForegroundColor DarkGray

# 4) Testa o proxy.
Write-Host "Testando o proxy..."
$proxyTestFile = Join-Path $env:TEMP "tlauncher-proxy-test.tmp"
Remove-Item $proxyTestFile -Force -ErrorAction SilentlyContinue
& curl.exe -4 --proxy $proxy --noproxy "" --max-time 15 -L -sS -I --output $proxyTestFile "https://tlauncher.org/"
$proxyTestExit = $LASTEXITCODE
Remove-Item $proxyTestFile -Force -ErrorAction SilentlyContinue
if ($proxyTestExit -ne 0) {
    Write-Host "O proxy abriu, mas o teste HTTPS falhou." -ForegroundColor Red
    [TLSocksProxy]::Stop()
    [TLBoundProxy]::Stop()
    Read-Host "Pressione ENTER para sair"
    exit 4
}

# 5) Baixa automaticamente a versao JAR oficial.
# IMPORTANTE: o download inicial usa --interface diretamente no IP do celular.
# Isso evita depender do proxy local durante redirects para o servidor de download.
$root = Join-Path $env:LOCALAPPDATA "TLauncherPortable"
$zip = Join-Path $root "TLauncher-JAR.zip"
$directJar = Join-Path $root "starter-core.jar"
$extract = Join-Path $root "jar"

New-Item -ItemType Directory -Path $root -Force | Out-Null

function Test-ZipLikeFile([string]$Path) {
    if (-not (Test-Path $Path)) { return $false }
    try {
        $fs = [IO.File]::OpenRead($Path)
        try {
            if ($fs.Length -lt 4) { return $false }
            $b0 = $fs.ReadByte()
            $b1 = $fs.ReadByte()
            return ($b0 -eq 0x50 -and $b1 -eq 0x4B) # PK: ZIP/JAR
        }
        finally { $fs.Dispose() }
    }
    catch { return $false }
}

$jar = $null

# Reaproveita um JAR valido de tentativa anterior.
$existing = @()
if (Test-Path $extract) {
    $existing += Get-ChildItem $extract -Recurse -Filter "*.jar" -File -ErrorAction SilentlyContinue
}
if (Test-ZipLikeFile $directJar) {
    $existing += Get-Item $directJar
}
$jar = $existing | Sort-Object LastWriteTime -Descending | Select-Object -First 1

if (-not $jar) {
    Write-Host "Baixando a versao JAR oficial do TLauncher..." -ForegroundColor Cyan
    Write-Host "Tentativa 1: https://tlauncher.org/jar (ZIP oficial)" -ForegroundColor DarkGray

    Remove-Item $zip -Force -ErrorAction SilentlyContinue
    Remove-Item $directJar -Force -ErrorAction SilentlyContinue
    if (Test-Path $extract) { Remove-Item $extract -Recurse -Force }

    # /jar redireciona para o host de download. --interface vale tambem para os redirects.
    $zipExit = 1

    if ($schoolIP) {
        Write-Host "Tentando baixar o JAR pela rede do curso primeiro..." -ForegroundColor DarkGray
        & curl.exe -4 -L --fail --show-error `
            --interface $schoolIP `
            --connect-timeout 12 --max-time 180 `
            "https://tlauncher.org/jar" `
            --output $zip
        $zipExit = $LASTEXITCODE
    }

    if ($zipExit -ne 0) {
        Write-Host "Rede do curso bloqueou o JAR; usando celular apenas para este arquivo." -ForegroundColor Yellow
        & curl.exe -4 -L --fail --show-error `
            --interface $bindIP `
            --connect-timeout 15 --max-time 240 `
            "https://tlauncher.org/jar" `
            --output $zip
        $zipExit = $LASTEXITCODE
    }

    if ($zipExit -eq 0 -and (Test-ZipLikeFile $zip)) {
        try {
            New-Item -ItemType Directory -Path $extract -Force | Out-Null
            Expand-Archive -LiteralPath $zip -DestinationPath $extract -Force

            $jar = Get-ChildItem $extract -Recurse -Filter "*.jar" -File -ErrorAction SilentlyContinue |
                Sort-Object LastWriteTime -Descending |
                Select-Object -First 1
        }
        catch {
            Write-Host "O ZIP foi baixado, mas nao extraiu corretamente. Tentando JAR direto..." -ForegroundColor Yellow
            $jar = $null
        }
    }

    if (-not $jar) {
        Write-Host "Tentativa 2: https://tlauncher.org/jar-only (JAR direto)" -ForegroundColor Yellow

        Remove-Item $directJar -Force -ErrorAction SilentlyContinue

        & curl.exe -4 -L --fail --show-error `
            --interface $bindIP `
            --connect-timeout 15 --max-time 240 `
            "https://tlauncher.org/jar-only" `
            --output $directJar

        $jarExit = $LASTEXITCODE

        if ($jarExit -eq 0 -and (Test-ZipLikeFile $directJar)) {
            $jar = Get-Item $directJar
        }
    }

    # Ultimo fallback: tenta o JAR direto atraves do proxy ja funcional.
    if (-not $jar) {
        Write-Host "Tentativa 3: JAR direto atraves do proxy local..." -ForegroundColor Yellow

        Remove-Item $directJar -Force -ErrorAction SilentlyContinue

        & curl.exe -4 -L --fail --show-error `
            --proxy $proxy --noproxy "" `
            --connect-timeout 15 --max-time 240 `
            "https://tlauncher.org/jar-only" `
            --output $directJar

        $jarExit = $LASTEXITCODE

        if ($jarExit -eq 0 -and (Test-ZipLikeFile $directJar)) {
            $jar = Get-Item $directJar
        }
    }
}

if (-not $jar) {
    Write-Host ""
    Write-Host "Nao consegui baixar um JAR valido pelas 3 rotas." -ForegroundColor Red
    Write-Host "O celular e o proxy local estao funcionando; a falha ficou no host de download do TLauncher."
    [TLSocksProxy]::Stop()
    [TLBoundProxy]::Stop()
    Read-Host "Pressione ENTER para sair"
    exit 5
}

Write-Host "JAR obtido: $($jar.FullName)" -ForegroundColor Green

# 6) Localiza o JAR do starter que contem o cliente HTTP do TLauncher.
Add-Type -AssemblyName System.IO.Compression -ErrorAction SilentlyContinue
Add-Type -AssemblyName System.IO.Compression.FileSystem -ErrorAction SilentlyContinue

$targetEntry = "by/gdev/http/download/config/HttpClientConfig.class"

function Test-JarEntry([string]$Path, [string]$EntryName) {
    if (-not (Test-Path $Path)) { return $false }
    $fs = $null
    $za = $null
    try {
        $fs = [IO.File]::Open($Path, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::ReadWrite)
        $za = New-Object IO.Compression.ZipArchive($fs, [IO.Compression.ZipArchiveMode]::Read)
        return ($null -ne $za.GetEntry($EntryName))
    }
    catch {
        return $false
    }
    finally {
        if ($za) { $za.Dispose() }
        if ($fs) { $fs.Dispose() }
    }
}

$candidates = @()
if ($jar -and (Test-Path $jar.FullName)) { $candidates += $jar.FullName }
if (Test-Path $directJar) { $candidates += $directJar }
if (Test-Path $extract) {
    $candidates += Get-ChildItem $extract -Recurse -Filter "*.jar" -File -ErrorAction SilentlyContinue |
        Select-Object -ExpandProperty FullName
}
$candidates = $candidates | Select-Object -Unique

$sourceJar = $null
foreach ($c in $candidates) {
    if (Test-JarEntry $c $targetEntry) {
        $sourceJar = $c
        break
    }
}

if (-not $sourceJar) {
    Write-Host ""
    Write-Host "O JAR foi baixado, mas nao achei a classe de rede do starter nele." -ForegroundColor Red
    Write-Host "Arquivos pesquisados:"
    $candidates | ForEach-Object { Write-Host " - $_" }
    [TLSocksProxy]::Stop()
    [TLBoundProxy]::Stop()
    Read-Host "Pressione ENTER para sair"
    exit 6
}

Write-Host "Starter encontrado: $sourceJar" -ForegroundColor Green

# 7) Cria uma COPIA local do JAR e troca somente HttpClientConfig.
# A classe original usa HttpClients.custom() sem proxy.
# Esta copia adiciona setProxy(127.0.0.1:<porta>).
# O JAR original baixado nao e alterado.
$patchedJar = Join-Path $root "TLauncher-starter-proxy-patched.jar"
Copy-Item $sourceJar $patchedJar -Force

$replacementClassB64 = @'
yv66vgAAADQAcwoAAgADBwAEDAAFAAYBABBqYXZhL2xhbmcvT2JqZWN0AQAGPGluaXQ+AQADKClWBwAIAQA8b3JnL2FwYWNoZS9odHRwL2ltcGwvY29ubi9Qb29saW5nSHR0cENsaWVudENvbm5lY3Rpb25NYW5hZ2VyCgAHAAMKAAcACwwADAANAQAVc2V0RGVmYXVsdE1heFBlclJvdXRlAQAEKEkpVgoABwAPDAAQAA0BAAtzZXRNYXhUb3RhbAoAEgATBwAUDAAVABYBACtvcmcvYXBhY2hlL2h0dHAvY2xpZW50L2NvbmZpZy9SZXF1ZXN0Q29uZmlnAQAGY3VzdG9tAQA3KClMb3JnL2FwYWNoZS9odHRwL2NsaWVudC9jb25maWcvUmVxdWVzdENvbmZpZyRCdWlsZGVyOwoAGAAZBwAaDAAbABwBADNvcmcvYXBhY2hlL2h0dHAvY2xpZW50L2NvbmZpZy9SZXF1ZXN0Q29uZmlnJEJ1aWxkZXIBABFzZXRDb25uZWN0VGltZW91dAEAOChJKUxvcmcvYXBhY2hlL2h0dHAvY2xpZW50L2NvbmZpZy9SZXF1ZXN0Q29uZmlnJEJ1aWxkZXI7CgAYAB4MAB8AHAEAEHNldFNvY2tldFRpbWVvdXQKABgAIQwAIgAjAQAFYnVpbGQBAC8oKUxvcmcvYXBhY2hlL2h0dHAvY2xpZW50L2NvbmZpZy9SZXF1ZXN0Q29uZmlnOwoAJQAmBwAnDAAVACgBACdvcmcvYXBhY2hlL2h0dHAvaW1wbC9jbGllbnQvSHR0cENsaWVudHMBADEoKUxvcmcvYXBhY2hlL2h0dHAvaW1wbC9jbGllbnQvSHR0cENsaWVudEJ1aWxkZXI7CQAqACsHACwMAC0ALgEAPm9yZy9hcGFjaGUvaHR0cC9pbXBsL2NsaWVudC9EZWZhdWx0Q29ubmVjdGlvbktlZXBBbGl2ZVN0cmF0ZWd5AQAISU5TVEFOQ0UBAEBMb3JnL2FwYWNoZS9odHRwL2ltcGwvY2xpZW50L0RlZmF1bHRDb25uZWN0aW9uS2VlcEFsaXZlU3RyYXRlZ3k7CgAwADEHADIMADMANAEALW9yZy9hcGFjaGUvaHR0cC9pbXBsL2NsaWVudC9IdHRwQ2xpZW50QnVpbGRlcgEAFHNldEtlZXBBbGl2ZVN0cmF0ZWd5AQBjKExvcmcvYXBhY2hlL2h0dHAvY29ubi9Db25uZWN0aW9uS2VlcEFsaXZlU3RyYXRlZ3k7KUxvcmcvYXBhY2hlL2h0dHAvaW1wbC9jbGllbnQvSHR0cENsaWVudEJ1aWxkZXI7CgAwADYMADcAOAEAFHNldENvbm5lY3Rpb25NYW5hZ2VyAQBjKExvcmcvYXBhY2hlL2h0dHAvY29ubi9IdHRwQ2xpZW50Q29ubmVjdGlvbk1hbmFnZXI7KUxvcmcvYXBhY2hlL2h0dHAvaW1wbC9jbGllbnQvSHR0cENsaWVudEJ1aWxkZXI7CgAwADoMADsAPAEAF3NldERlZmF1bHRSZXF1ZXN0Q29uZmlnAQBeKExvcmcvYXBhY2hlL2h0dHAvY2xpZW50L2NvbmZpZy9SZXF1ZXN0Q29uZmlnOylMb3JnL2FwYWNoZS9odHRwL2ltcGwvY2xpZW50L0h0dHBDbGllbnRCdWlsZGVyOwoAMAA+DAA/ACgBABlkaXNhYmxlQ29udGVudENvbXByZXNzaW9uCABBAQAPaHR0cHMucHJveHlIb3N0CgBDAEQHAEUMAEYARwEAEGphdmEvbGFuZy9TeXN0ZW0BAAtnZXRQcm9wZXJ0eQEAJihMamF2YS9sYW5nL1N0cmluZzspTGphdmEvbGFuZy9TdHJpbmc7CABJAQAPaHR0cHMucHJveHlQb3J0CgBLAEwHAE0MAE4ATwEAEGphdmEvbGFuZy9TdHJpbmcBAAR0cmltAQAUKClMamF2YS9sYW5nL1N0cmluZzsKAEsAUQwAUgBTAQAHaXNFbXB0eQEAAygpWgoAVQBWBwBXDABYAFkBABFqYXZhL2xhbmcvSW50ZWdlcgEACHBhcnNlSW50AQAVKExqYXZhL2xhbmcvU3RyaW5nOylJBwBbAQATamF2YS9sYW5nL0V4Y2VwdGlvbgcAXQEAGG9yZy9hcGFjaGUvaHR0cC9IdHRwSG9zdAoAXABfDAAFAGABABYoTGphdmEvbGFuZy9TdHJpbmc7SSlWCgAwAGIMAGMAZAEACHNldFByb3h5AQBLKExvcmcvYXBhY2hlL2h0dHAvSHR0cEhvc3Q7KUxvcmcvYXBhY2hlL2h0dHAvaW1wbC9jbGllbnQvSHR0cENsaWVudEJ1aWxkZXI7CgAwAGYMACIAZwEAMygpTG9yZy9hcGFjaGUvaHR0cC9pbXBsL2NsaWVudC9DbG9zZWFibGVIdHRwQ2xpZW50OwcAaQEALWJ5L2dkZXYvaHR0cC9kb3dubG9hZC9jb25maWcvSHR0cENsaWVudENvbmZpZwEABENvZGUBAA9MaW5lTnVtYmVyVGFibGUBABVnZXRJbnN0YW5jZUh0dHBDbGllbnQBADcoSUlJSSlMb3JnL2FwYWNoZS9odHRwL2ltcGwvY2xpZW50L0Nsb3NlYWJsZUh0dHBDbGllbnQ7AQANU3RhY2tNYXBUYWJsZQEAClNvdXJjZUZpbGUBABVIdHRwQ2xpZW50Q29uZmlnLmphdmEBAAxJbm5lckNsYXNzZXMBAAdCdWlsZGVyACEAaAACAAAAAAACAAEABQAGAAEAagAAAB0AAQABAAAABSq3AAGxAAAAAQBrAAAABgABAAAACwAJAGwAbQABAGoAAAEVAAUACwAAAIO7AAdZtwAJOgQZBBy2AAoZBB22AA64ABEatgAXG7YAHbYAIDoFuAAksgAptgAvGQS2ADUZBbYAObYAPToGEkC4AEI6BxJIuABCOggZB8YAMBkHtgBKtgBQmgAlER+QNgkZCLgAVDYJpwAFOgoZBrsAXFkZBxUJtwBetgBhVxkGtgBlsAABAGAAZwBqAFoAAgBrAAAATgATAAAADQAJAA4ADwAPABUAEQAZABIAHQATACAAFAAlABYAKwAXADAAGAA1ABkAOAAaAD0AHABEAB0ASwAeAFsAHwBgACAAbAAhAH0AJABuAAAAJAAD/wBqAAoBAQEBBwAHBwASBwAwBwBLBwBLAQABBwBaAfoAEAACAG8AAAACAHAAcQAAAAoAAQAYABIAcgAJ
'@

$replacementBytes = [Convert]::FromBase64String(($replacementClassB64 -replace '\s',''))

$fs = $null
$za = $null
try {
    $fs = [IO.File]::Open($patchedJar, [IO.FileMode]::Open, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
    $za = New-Object IO.Compression.ZipArchive($fs, [IO.Compression.ZipArchiveMode]::Update)

    # Remove a classe original e metadados de assinatura da COPIA,
    # pois a troca de uma classe invalida a assinatura do arquivo.
    $toDelete = @()
    foreach ($e in $za.Entries) {
        $name = $e.FullName
        if ($name -eq $targetEntry -or
            $name -match '^META-INF/[^/]+\.(SF|RSA|DSA|EC)$' -or
            $name -match '^META-INF/SIG-') {
            $toDelete += $e
        }
    }
    foreach ($e in $toDelete) { $e.Delete() }

    $entry = $za.CreateEntry($targetEntry, [IO.Compression.CompressionLevel]::Optimal)
    $stream = $entry.Open()
    try {
        $stream.Write($replacementBytes, 0, $replacementBytes.Length)
    }
    finally {
        $stream.Dispose()
    }
}
catch {
    Write-Host ""
    Write-Host "Falha ao criar a copia corrigida do JAR:" -ForegroundColor Red
    Write-Host $_.Exception.Message
    [TLSocksProxy]::Stop()
    [TLBoundProxy]::Stop()
    Read-Host "Pressione ENTER para sair"
    exit 7
}
finally {
    if ($za) { $za.Dispose() }
    if ($fs) { $fs.Dispose() }
}

if (-not (Test-JarEntry $patchedJar $targetEntry)) {
    Write-Host "A copia foi criada, mas a classe corrigida nao apareceu dentro dela." -ForegroundColor Red
    [TLSocksProxy]::Stop()
    [TLBoundProxy]::Stop()
    Read-Host "Pressione ENTER para sair"
    exit 8
}

Write-Host "Copia corrigida: $patchedJar" -ForegroundColor Green

# 8) Procura Java. Prefere Java 8 se existir; senao usa o java padrao.
$javaCandidates = New-Object System.Collections.Generic.List[string]

$common = @(
    "$env:ProgramFiles\Java",
    "${env:ProgramFiles(x86)}\Java",
    "$env:LOCALAPPDATA\Programs\Java"
)

foreach ($base in $common) {
    if ($base -and (Test-Path $base)) {
        Get-ChildItem $base -Recurse -Filter "java.exe" -File -ErrorAction SilentlyContinue |
            ForEach-Object { if (-not $javaCandidates.Contains($_.FullName)) { $javaCandidates.Add($_.FullName) } }
    }
}

$cmdJava = Get-Command java.exe -ErrorAction SilentlyContinue
if ($cmdJava -and -not $javaCandidates.Contains($cmdJava.Source)) {
    $javaCandidates.Add($cmdJava.Source)
}

if ($javaCandidates.Count -eq 0) {
    Write-Host "Java nao foi encontrado neste PC." -ForegroundColor Red
    [TLSocksProxy]::Stop()
    [TLBoundProxy]::Stop()
    Read-Host "Pressione ENTER para sair"
    exit 9
}

$java = $null
foreach ($candidate in $javaCandidates) {
    try {
        $v = (& $candidate -version 2>&1 | Out-String)
        if ($v -match 'version\s+"1\.8\.') {
            $java = $candidate
            break
        }
    } catch {}
}
if (-not $java) { $java = $javaCandidates[0] }

Write-Host "Java: $java" -ForegroundColor Green

# 9) A classe corrigida le estas propriedades e FORCA o Apache HttpClient
# interno do starter a usar nosso proxy local.
$env:HTTP_PROXY  = $proxy
$env:HTTPS_PROXY = $proxy
$env:ALL_PROXY   = $proxy
$env:JAVA_TOOL_OPTIONS = "-Djava.net.useSystemProxies=false -Djava.net.preferIPv4Stack=true -Dhttp.proxyHost=127.0.0.1 -Dhttp.proxyPort=$proxyPort -Dhttps.proxyHost=127.0.0.1 -Dhttps.proxyPort=$proxyPort -DsocksProxyHost=127.0.0.1 -DsocksProxyPort=$socksPort -DsocksProxyVersion=5"

Write-Host ""
Write-Host "Abrindo TLauncher com o cliente HTTP corrigido..." -ForegroundColor Cyan
Write-Host "Mantenha esta janela aberta enquanto usar o launcher." -ForegroundColor Yellow
Write-Host ""

$runtimeLog = Join-Path $root "tlauncher-v11-runtime.log"
$stdoutLog  = Join-Path $root "tlauncher-v11-stdout.log"
$stderrLog  = Join-Path $root "tlauncher-v11-stderr.log"

Remove-Item $runtimeLog,$stdoutLog,$stderrLog -Force -ErrorAction SilentlyContinue

Write-Host "Executando Java na MESMA janela..." -ForegroundColor DarkGray
Write-Host "Logs: $runtimeLog" -ForegroundColor DarkGray
Write-Host ""

try {
    # Forma mais simples/robusta no Windows PowerShell 5:
    # deixa o .NET/Start-Process cuidar dos pipes, sem callbacks em threads
    # que podem encerrar o PowerShell por falta de Runspace.
    $proc = Start-Process `
        -FilePath $java `
        -ArgumentList @("-jar", "`"$patchedJar`"") `
        -NoNewWindow `
        -PassThru `
        -Wait `
        -RedirectStandardOutput $stdoutLog `
        -RedirectStandardError $stderrLog

    $stdoutText = ""
    $stderrText = ""

    if (Test-Path $stdoutLog) {
        $stdoutText = Get-Content $stdoutLog -Raw -ErrorAction SilentlyContinue
    }

    if (Test-Path $stderrLog) {
        $stderrText = Get-Content $stderrLog -Raw -ErrorAction SilentlyContinue
    }

    $all = @(
        "=== STDOUT ==="
        $stdoutText
        ""
        "=== STDERR ==="
        $stderrText
        ""
        "=== EXIT CODE ==="
        [string]$proc.ExitCode
    ) -join [Environment]::NewLine

    [IO.File]::WriteAllText(
        $runtimeLog,
        $all,
        (New-Object Text.UTF8Encoding($false))
    )

    if ($stdoutText) {
        Write-Host "=== JAVA STDOUT ===" -ForegroundColor Cyan
        Write-Host $stdoutText
    }

    if ($stderrText) {
        Write-Host "=== JAVA STDERR ===" -ForegroundColor DarkYellow
        Write-Host $stderrText
    }

    Write-Host ""
    Write-Host "TLauncher terminou. Codigo de saida: $($proc.ExitCode)" -ForegroundColor Yellow
}
catch {
    $msg = $_.Exception.ToString()

    [IO.File]::WriteAllText(
        $runtimeLog,
        $msg,
        (New-Object Text.UTF8Encoding($false))
    )

    Write-Host ""
    Write-Host "Falha real ao iniciar/executar o Java:" -ForegroundColor Red
    Write-Host $msg

    if (Test-Path $stderrLog) {
        Write-Host ""
        Write-Host "=== STDERR CAPTURADO ===" -ForegroundColor DarkYellow
        Get-Content $stderrLog -Tail 100
    }
}
finally {
    $phoneUsed =
        [TLBoundProxy]::GetPhoneBytes() +
        [TLSocksProxy]::GetPhoneBytes()

    $schoolUsed =
        [TLBoundProxy]::GetSchoolBytes() +
        [TLSocksProxy]::GetSchoolBytes()

    Write-Host ""
    Write-Host "=== USO DE REDE DA SESSAO (HTTP + SOCKS) ===" -ForegroundColor Cyan
    Write-Host ("Rede do curso: {0:N2} MB" -f ($schoolUsed / 1MB)) -ForegroundColor Green
    Write-Host ("Dados moveis:   {0:N2} MB" -f ($phoneUsed / 1MB)) -ForegroundColor Yellow

    [TLSocksProxy]::Stop()
    [TLBoundProxy]::Stop()
}

Write-Host ""
Write-Host "Log salvo em: $runtimeLog" -ForegroundColor DarkGray
Write-Host "A janela NAO vai fechar sozinha." -ForegroundColor DarkGray
Read-Host "Pressione ENTER para fechar"
