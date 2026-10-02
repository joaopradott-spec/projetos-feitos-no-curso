$ErrorActionPreference = "Stop"
$Host.UI.RawUI.WindowTitle = "Roblox Studio - instalar e abrir"

Write-Host "=== Roblox Studio - instalacao automatica ===" -ForegroundColor Cyan
Write-Host "Sem admin. Rede do curso primeiro; celular como fallback." -ForegroundColor DarkGray
Write-Host ""

function Find-RobloxStudio {
    Get-ChildItem "$env:LOCALAPPDATA\Roblox\Versions" `
        -Recurse `
        -Filter "RobloxStudioBeta.exe" `
        -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending |
        Select-Object -First 1
}

# 1) Detecta o tether USB.
$phone = Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue |
    Where-Object {
        $_.AddressState -eq "Preferred" -and
        $_.IPAddress -like "192.168.42.*"
    } |
    Select-Object -First 1

if (-not $phone) {
    Write-Host "Nao encontrei o tether USB do celular (192.168.42.x)." -ForegroundColor Red
    Write-Host "Ative o roteamento USB e tente novamente."
    Read-Host "Pressione ENTER para sair"
    exit 1
}

$bindIP = $phone.IPAddress
Write-Host "Celular: $($phone.InterfaceAlias) - $bindIP" -ForegroundColor Green

# 2) Descobre a outra rota padrao (normalmente a rede do curso).
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
        Write-Host "Rede principal: $($schoolAddr.InterfaceAlias) - $schoolIP" -ForegroundColor Green
    }
}

if (-not $schoolIP) {
    Write-Host "Outra rota nao encontrada; o proxy usara o celular." -ForegroundColor Yellow
}

# 3) Proxy HTTP/HTTPS split-routing.
$code = @'
using System;
using System.IO;
using System.Net;
using System.Net.Sockets;
using System.Net.Security;
using System.Text;
using System.Threading;
using System.Collections.Generic;

public static class RobloxSplitProxy
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
'@

Add-Type -TypeDefinition $code

$proxyPort = $null
$budgetBytes = [int64]::MaxValue

foreach ($p in 18081..18120) {
    if ([RobloxSplitProxy]::TryStart($bindIP, $schoolIP, $p, $budgetBytes)) {
        $proxyPort = $p
        break
    }
}

if (-not $proxyPort) {
    Write-Host "Nao consegui abrir uma porta para o proxy local." -ForegroundColor Red
    Read-Host "Pressione ENTER para sair"
    exit 2
}

$proxy = "http://127.0.0.1:$proxyPort"
Write-Host "Proxy local: $proxy" -ForegroundColor Green

$oldHTTP = $env:HTTP_PROXY
$oldHTTPS = $env:HTTPS_PROXY
$oldALL = $env:ALL_PROXY
$oldCompat = $env:__COMPAT_LAYER

# Salva o proxy WinINET do usuario para poder restaurar exatamente depois.
$inetKey = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings"
$oldProxyEnable = $null
$oldProxyServer = $null
$oldProxyOverride = $null
$hadProxyEnable = $false
$hadProxyServer = $false
$hadProxyOverride = $false

try {
    $props = Get-ItemProperty $inetKey -ErrorAction SilentlyContinue
    if ($null -ne $props) {
        if ($null -ne $props.ProxyEnable) {
            $oldProxyEnable = $props.ProxyEnable
            $hadProxyEnable = $true
        }
        if ($null -ne $props.ProxyServer) {
            $oldProxyServer = $props.ProxyServer
            $hadProxyServer = $true
        }
        if ($null -ne $props.ProxyOverride) {
            $oldProxyOverride = $props.ProxyOverride
            $hadProxyOverride = $true
        }
    }

    # 4) Testa um endpoint do Roblox pelo split proxy.
    Write-Host ""
    Write-Host "Testando acesso ao Roblox..." -ForegroundColor Cyan
    $testFile = Join-Path $env:TEMP "roblox-studio-net-test.tmp"
    Remove-Item $testFile -Force -ErrorAction SilentlyContinue

    & curl.exe -4 `
        --proxy $proxy `
        --noproxy "" `
        --connect-timeout 10 `
        --max-time 20 `
        -L -sS `
        --output $testFile `
        -w "HTTP %%{http_code}`n" `
        "https://apis.roblox.com/universal-app-configuration/v1/behaviors/studio/content"

    $testExit = $LASTEXITCODE
    Remove-Item $testFile -Force -ErrorAction SilentlyContinue

    if ($testExit -ne 0) {
        throw "O teste de rede do Roblox falhou."
    }

    # 5) Se o Studio ainda nao existir, baixa o bootstrapper oficial e instala.
    $studio = Find-RobloxStudio

    if (-not $studio) {
        Write-Host ""
        Write-Host "Roblox Studio nao encontrado. Instalando automaticamente..." -ForegroundColor Yellow

        $toolsDir = Join-Path $env:LOCALAPPDATA "RobloxCourseTools"
        New-Item -ItemType Directory -Force -Path $toolsDir | Out-Null

        $installer = Join-Path $toolsDir "RobloxStudioLauncherBeta.exe"
        $installerUrl = "https://setup.rbxcdn.com/RobloxStudioLauncherBeta.exe"

        Write-Host "Baixando o instalador oficial..." -ForegroundColor Cyan
        Remove-Item $installer -Force -ErrorAction SilentlyContinue

        & curl.exe -4 `
            --proxy $proxy `
            --noproxy "" `
            --connect-timeout 15 `
            --max-time 300 `
            --retry 3 `
            --retry-delay 2 `
            -L --fail --show-error `
            --output $installer `
            $installerUrl

        if ($LASTEXITCODE -ne 0 -or -not (Test-Path $installer)) {
            throw "Nao consegui baixar RobloxStudioLauncherBeta.exe."
        }

        # Verificacao simples de executavel PE: deve comecar por MZ.
        $fs = [System.IO.File]::OpenRead($installer)
        try {
            $mz1 = $fs.ReadByte()
            $mz2 = $fs.ReadByte()
        }
        finally {
            $fs.Dispose()
        }

        if ($mz1 -ne 77 -or $mz2 -ne 90) {
            throw "O arquivo baixado nao parece ser um executavel Windows valido."
        }

        Write-Host "Instalador salvo em: $installer" -ForegroundColor DarkGray
        Write-Host "Executando instalacao no perfil do usuario..." -ForegroundColor Cyan

        # A maioria dos clientes respeita pelo menos uma destas duas formas.
        # O registro WinINET e alterado apenas durante a instalacao e restaurado depois.
        $env:HTTP_PROXY = $proxy
        $env:HTTPS_PROXY = $proxy
        $env:ALL_PROXY = $proxy
        $env:__COMPAT_LAYER = "RunAsInvoker"

        Set-ItemProperty -Path $inetKey -Name ProxyEnable -Value 1
        Set-ItemProperty -Path $inetKey -Name ProxyServer -Value "http=127.0.0.1:$proxyPort;https=127.0.0.1:$proxyPort"
        Set-ItemProperty -Path $inetKey -Name ProxyOverride -Value "<local>"

        try {
            $installerProc = Start-Process -FilePath $installer -PassThru
            $installerProc.WaitForExit()
        }
        finally {
            # Restaura WinINET logo depois da instalacao.
            if ($hadProxyEnable) {
                Set-ItemProperty -Path $inetKey -Name ProxyEnable -Value $oldProxyEnable
            } else {
                Remove-ItemProperty -Path $inetKey -Name ProxyEnable -ErrorAction SilentlyContinue
            }

            if ($hadProxyServer) {
                Set-ItemProperty -Path $inetKey -Name ProxyServer -Value $oldProxyServer
            } else {
                Remove-ItemProperty -Path $inetKey -Name ProxyServer -ErrorAction SilentlyContinue
            }

            if ($hadProxyOverride) {
                Set-ItemProperty -Path $inetKey -Name ProxyOverride -Value $oldProxyOverride
            } else {
                Remove-ItemProperty -Path $inetKey -Name ProxyOverride -ErrorAction SilentlyContinue
            }
        }

        Write-Host "Aguardando o Studio aparecer em AppData..." -ForegroundColor DarkGray

        for ($i = 0; $i -lt 90; $i++) {
            $studio = Find-RobloxStudio
            if ($studio) { break }
            Start-Sleep -Seconds 2
        }

        if (-not $studio) {
            throw "O instalador terminou, mas RobloxStudioBeta.exe nao apareceu em AppData."
        }

        Write-Host "Instalacao concluida." -ForegroundColor Green
    }
    else {
        Write-Host ""
        Write-Host "Roblox Studio ja esta instalado." -ForegroundColor Green
    }

    Write-Host "Studio: $($studio.FullName)" -ForegroundColor Green

    # 6) Se o bootstrapper ja abriu o Studio, usa esse processo.
    $runningStudio = Get-Process -Name "RobloxStudioBeta" -ErrorAction SilentlyContinue |
        Select-Object -First 1

    if ($runningStudio) {
        Write-Host "O instalador ja abriu o Studio. Mantendo o proxy ativo..." -ForegroundColor Cyan
        $studioProc = $runningStudio
    }
    else {
        Write-Host "Abrindo Roblox Studio pelo proxy..." -ForegroundColor Cyan

        $env:HTTP_PROXY = $proxy
        $env:HTTPS_PROXY = $proxy
        $env:ALL_PROXY = $proxy
        $env:__COMPAT_LAYER = $oldCompat

        $studioProc = Start-Process -FilePath $studio.FullName -PassThru
    }

    # O processo filho ja herdou o ambiente; restaura este PowerShell.
    $env:HTTP_PROXY = $oldHTTP
    $env:HTTPS_PROXY = $oldHTTPS
    $env:ALL_PROXY = $oldALL
    $env:__COMPAT_LAYER = $oldCompat

    Write-Host ""
    Write-Host "Mantenha esta janela aberta enquanto usar o Studio." -ForegroundColor Yellow
    $studioProc.WaitForExit()
}
catch {
    Write-Host ""
    Write-Host "ERRO: $($_.Exception.Message)" -ForegroundColor Red
    Read-Host "Pressione ENTER para fechar"
}
finally {
    # Restaura tudo mesmo se houver erro/interrupcao.
    $env:HTTP_PROXY = $oldHTTP
    $env:HTTPS_PROXY = $oldHTTPS
    $env:ALL_PROXY = $oldALL
    $env:__COMPAT_LAYER = $oldCompat

    try {
        if ($hadProxyEnable) {
            Set-ItemProperty -Path $inetKey -Name ProxyEnable -Value $oldProxyEnable -ErrorAction SilentlyContinue
        } else {
            Remove-ItemProperty -Path $inetKey -Name ProxyEnable -ErrorAction SilentlyContinue
        }

        if ($hadProxyServer) {
            Set-ItemProperty -Path $inetKey -Name ProxyServer -Value $oldProxyServer -ErrorAction SilentlyContinue
        } else {
            Remove-ItemProperty -Path $inetKey -Name ProxyServer -ErrorAction SilentlyContinue
        }

        if ($hadProxyOverride) {
            Set-ItemProperty -Path $inetKey -Name ProxyOverride -Value $oldProxyOverride -ErrorAction SilentlyContinue
        } else {
            Remove-ItemProperty -Path $inetKey -Name ProxyOverride -ErrorAction SilentlyContinue
        }
    } catch {}

    $phoneUsed = [RobloxSplitProxy]::GetPhoneBytes()
    $schoolUsed = [RobloxSplitProxy]::GetSchoolBytes()

    Write-Host ""
    Write-Host "=== USO DE REDE OBSERVADO PELO PROXY ===" -ForegroundColor Cyan
    Write-Host ("Rede principal: {0:N2} MB" -f ($schoolUsed / 1MB)) -ForegroundColor Green
    Write-Host ("Dados moveis:   {0:N2} MB" -f ($phoneUsed / 1MB)) -ForegroundColor Yellow

    [RobloxSplitProxy]::Stop()
}

Write-Host ""
Write-Host "Finalizado." -ForegroundColor DarkGray
