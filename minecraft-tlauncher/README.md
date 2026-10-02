# Minecraft funcional — TLauncher

Versão funcional baseada no **v11 Dual Proxy**.

Ela usa duas camadas de proxy locais:

- HTTP/HTTPS para o starter e clientes HTTP;
- SOCKS5 para a camada TCP da JVM/TLauncher principal.

A lógica tenta a rede principal primeiro e usa o tether USB como fallback quando um host falha ou sofre reset.

## Uso

1. Ative a rede do curso e o tether USB.
2. Execute `TLauncher v11 DUAL PROXY.cmd`.
3. Mantenha a janela aberta enquanto usar o launcher.

## Logs

```text
%LOCALAPPDATA%\TLauncherPortable\tlauncher-v11-runtime.log
%LOCALAPPDATA%\TLauncherPortable\tlauncher-v11-stdout.log
%LOCALAPPDATA%\TLauncherPortable\tlauncher-v11-stderr.log
```

## Observação sobre dados móveis

O fallback pode consumir franquia de dados móveis. O objetivo do split routing é preferir a rede principal e usar o celular somente nos destinos em que a rota principal falhar.
