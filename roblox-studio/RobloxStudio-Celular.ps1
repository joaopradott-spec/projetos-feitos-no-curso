$ErrorActionPreference = "Stop"
$Host.UI.RawUI.WindowTitle = "Roblox Studio pelo celular"

Write-Host "=== Roblox Studio pelo celular ===" -ForegroundColor Cyan
Write-Host "O proxy fica preso ao tether USB do celular." -ForegroundColor DarkGray
Write-Host ""

$phone = Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue |
    Where-Object {
        $_.AddressState -eq "Preferred" -and
        $_.IPAddress -like "192.168.42.*"
    } |
    Select-Object -First 1

if (-not $phone) {
    Write-Host "Nao encontrei o tether USB (192.168.42.x)." -ForegroundColor Red
    Read-Host "Ative o roteamento USB e pressione ENTER para sair"
    exit 1
}

$bindIP = $phone.IPAddress
Write-Host "Celular detectado: $($phone.InterfaceAlias) - $bindIP" -ForegroundColor Green

$code = @'
using System;
using System.IO;
using System.Net;
using System.Net.Sockets;
using System.Text;
using System.Threading;

public static class RobloxPhoneProxy
{
    static string bindIp;
    static TcpListener listener;
    static volatile bool running;

    public static bool TryStart(string ip, int port)
    {
        try
        {
            bindIp = ip;
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

    static void AcceptLoop()
    {
        while (running)
        {
            try
            {
                TcpClient client = listener.AcceptTcpClient();
                Thread t = new Thread(() => Handle(client));
                t.IsBackground = true;
                t.Start();
            }
            catch
            {
                if (!running) return;
            }
        }
    }

    static Socket ConnectBound(string host, int port)
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
                s.Bind(new IPEndPoint(IPAddress.Parse(bindIp), 0));
                s.Connect(addr, port);
                return s;
            }
            catch (Exception ex)
            {
                last = ex;
                try { if (s != null) s.Close(); } catch {}
            }
        }

        throw last ?? new Exception("Nao foi possivel conectar em " + host);
    }

    static void Handle(TcpClient client)
    {
        Socket remote = null;

        try
        {
            NetworkStream local = client.GetStream();
            byte[] headerBytes = ReadHeader(local);

            if (headerBytes == null)
            {
                client.Close();
                return;
            }

            string header = Encoding.ASCII.GetString(headerBytes);
            string first = header.Split(
                new string[] { "\r\n" },
                StringSplitOptions.None
            )[0];

            string[] p = first.Split(' ');

            if (p.Length < 2 || !p[0].Equals("CONNECT", StringComparison.OrdinalIgnoreCase))
            {
                Send(local, "HTTP/1.1 405 Method Not Allowed\r\nConnection: close\r\n\r\n");
                client.Close();
                return;
            }

            string target = p[1];
            int colon = target.LastIndexOf(':');
            string host = colon > 0 ? target.Substring(0, colon) : target;
            int port = colon > 0 ? Int32.Parse(target.Substring(colon + 1)) : 443;

            remote = ConnectBound(host, port);
            NetworkStream internet = new NetworkStream(remote, true);

            Send(local, "HTTP/1.1 200 Connection Established\r\n\r\n");

            Thread a = new Thread(() => Pump(local, internet));
            Thread b = new Thread(() => Pump(internet, local));

            a.IsBackground = true;
            b.IsBackground = true;

            a.Start();
            b.Start();

            a.Join();

            try { client.Close(); } catch {}
            try { internet.Close(); } catch {}
        }
        catch
        {
            try
            {
                Send(client.GetStream(),
                    "HTTP/1.1 502 Bad Gateway\r\nConnection: close\r\n\r\n");
            }
            catch {}

            try { client.Close(); } catch {}
            try { if (remote != null) remote.Close(); } catch {}
        }
    }

    static byte[] ReadHeader(Stream s)
    {
        MemoryStream ms = new MemoryStream();
        int state = 0;

        while (ms.Length < 32768)
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

    static void Pump(Stream input, Stream output)
    {
        try
        {
            byte[] buf = new byte[65536];
            int n;

            while ((n = input.Read(buf, 0, buf.Length)) > 0)
            {
                output.Write(buf, 0, n);
                output.Flush();
            }
        }
        catch {}
    }

    static void Send(Stream s, string text)
    {
        byte[] b = Encoding.ASCII.GetBytes(text);
        s.Write(b, 0, b.Length);
        s.Flush();
    }
}
'@

Add-Type -TypeDefinition $code

$port = $null
foreach ($p in 18081..18120) {
    if ([RobloxPhoneProxy]::TryStart($bindIP, $p)) {
        $port = $p
        break
    }
}

if (-not $port) {
    Write-Host "Nao consegui abrir uma porta local para o proxy." -ForegroundColor Red
    Read-Host "ENTER para sair"
    exit 2
}

$proxy = "http://127.0.0.1:$port"
Write-Host "Proxy ativo: $proxy" -ForegroundColor Green

# Valida o endpoint que anteriormente bloqueava a inicializacao do Studio.
$test = Join-Path $env:TEMP "roblox-guac-test.tmp"
Remove-Item $test -Force -ErrorAction SilentlyContinue

& curl.exe -4 `
    --proxy $proxy `
    --noproxy "" `
    --max-time 15 `
    -sS `
    -o $test `
    -w "Teste GUAC: HTTP %{http_code}`n" `
    "https://apis.roblox.com/universal-app-configuration/v1/behaviors/studio/content"

$curlExit = $LASTEXITCODE
Remove-Item $test -Force -ErrorAction SilentlyContinue

if ($curlExit -ne 0) {
    Write-Host "O proxy abriu, mas o teste de rede falhou." -ForegroundColor Red
    [RobloxPhoneProxy]::Stop()
    Read-Host "ENTER para sair"
    exit 3
}

$studio = Get-ChildItem "$env:LOCALAPPDATA\Roblox\Versions" `
    -Recurse `
    -Filter "RobloxStudioBeta.exe" `
    -ErrorAction SilentlyContinue |
    Sort-Object LastWriteTime -Descending |
    Select-Object -First 1

if (-not $studio) {
    Write-Host "RobloxStudioBeta.exe nao foi encontrado." -ForegroundColor Red
    [RobloxPhoneProxy]::Stop()
    Read-Host "ENTER para sair"
    exit 4
}

Write-Host "Studio: $($studio.FullName)" -ForegroundColor Green
Write-Host "Abrindo Roblox Studio..." -ForegroundColor Cyan
Write-Host "Mantenha esta janela aberta enquanto usar o Studio." -ForegroundColor Yellow
Write-Host ""

$oldHTTP  = $env:HTTP_PROXY
$oldHTTPS = $env:HTTPS_PROXY
$oldALL   = $env:ALL_PROXY

try {
    $env:HTTP_PROXY  = $proxy
    $env:HTTPS_PROXY = $proxy
    $env:ALL_PROXY   = $proxy

    $proc = Start-Process $studio.FullName -PassThru

    # Restaura o ambiente deste PowerShell; o Studio ja herdou o proxy.
    $env:HTTP_PROXY  = $oldHTTP
    $env:HTTPS_PROXY = $oldHTTPS
    $env:ALL_PROXY   = $oldALL

    $proc.WaitForExit()
}
finally {
    $env:HTTP_PROXY  = $oldHTTP
    $env:HTTPS_PROXY = $oldHTTPS
    $env:ALL_PROXY   = $oldALL
    [RobloxPhoneProxy]::Stop()
}

Write-Host ""
Write-Host "Roblox Studio encerrado; proxy finalizado." -ForegroundColor DarkGray
Read-Host "ENTER para fechar"
