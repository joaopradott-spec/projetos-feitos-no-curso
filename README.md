# Projetos feitos no curso

Repositório com soluções desenvolvidas/testadas durante o curso.

## Projetos

### Roblox Studio funcional

Pasta: [`roblox-studio/`](./roblox-studio)

Abre o Roblox Studio com um proxy local preso ao tether USB, permitindo que o Studio consulte os serviços de rede necessários sem exigir privilégios administrativos.

### Minecraft funcional — TLauncher

Pasta: [`minecraft-tlauncher/`](./minecraft-tlauncher)

Versão v11 Dual Proxy: usa HTTP/HTTPS + SOCKS5, prefere a rede principal e usa a conexão do celular como fallback quando necessário.

## Estrutura

```text
projetos-feitos-no-curso/
├── README.md
├── .gitignore
├── roblox-studio/
│   ├── README.md
│   ├── RobloxStudio-Celular.ps1
│   └── Abrir Roblox Studio.cmd
└── minecraft-tlauncher/
    ├── README.md
    ├── TLauncher-Celular.ps1
    └── TLauncher v11 DUAL PROXY.cmd
```

## Requisitos gerais

- Windows 10/11
- PowerShell 5+
- permissões de usuário comum
- tether USB disponível para os fluxos que precisam da conexão secundária

## Uso responsável

Use apenas em redes, máquinas e ambientes em que você tenha autorização para executar e testar essas soluções.
