# Roblox Studio funcional — instalação automática

Agora esta pasta funciona também em um PC do curso onde o Studio ainda **não está instalado**.

## Uso

1. Ative a rede normal do PC.
2. Conecte o celular por USB e ative o roteamento USB.
3. Execute `Abrir Roblox Studio.cmd`.
4. Mantenha a janela aberta enquanto usar o Studio.

## O que o script faz

- detecta o tether USB;
- detecta a outra rota de rede;
- inicia um proxy HTTP/HTTPS local;
- prefere a rede principal e usa o celular como fallback;
- testa um endpoint necessário do Roblox;
- procura `RobloxStudioBeta.exe`;
- se o Studio não existir:
  - baixa `RobloxStudioLauncherBeta.exe` do CDN oficial da Roblox;
  - executa a instalação no perfil do usuário;
  - aguarda o Studio aparecer em `%LOCALAPPDATA%\Roblox\Versions`;
- abre o Studio usando o proxy;
- restaura as configurações de proxy temporárias ao terminar.

## Onde o Studio fica

Normalmente:

```text
%LOCALAPPDATA%\Roblox\Versions\version-...\RobloxStudioBeta.exe
```

## Importante

O instalador não fica dentro do Git. Ele é baixado somente quando necessário, para evitar guardar um executável grande e desatualizado no repositório.

O fallback pelo celular pode consumir dados móveis quando a rede principal bloquear um destino.
