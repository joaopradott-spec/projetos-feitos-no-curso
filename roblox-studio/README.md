# Roblox Studio funcional

Launcher para o Roblox Studio usando um proxy HTTP CONNECT local cujo tráfego de saída é preso ao tether USB do celular.

## Uso

1. Ative o roteamento USB do celular.
2. Confirme que o Roblox Studio já está instalado.
3. Execute `Abrir Roblox Studio.cmd`.
4. Mantenha a janela aberta enquanto usa o Studio.

O script procura automaticamente a versão mais recente de `RobloxStudioBeta.exe` em `%LOCALAPPDATA%\Roblox\Versions`.

## Motivo

Em algumas redes gerenciadas, o Studio abre mas falha ao consultar serviços necessários para inicialização. O script mantém somente o processo iniciado usando o proxy local e não exige privilégios administrativos.
