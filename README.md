# fin

A headless model gateway for agents. One endpoint, configurable providers and account pools, live configuration, and usage tracking.

This repository distributes signed binaries. Source development and release checks run separately; no GitHub Actions are used here.

## Install

Linux / macOS — requires curl, jq, and OpenSSL with Ed25519 support (OpenSSL 3 recommended):

```sh
curl -qfsSL --proto '=https' --proto-redir '=https' https://raw.githubusercontent.com/fin-hq/fin-releases/main/install.sh | sh
```

Windows PowerShell — requires curl.exe and OpenSSL with Ed25519 support:

```powershell
& ([scriptblock]::Create((Invoke-RestMethod https://raw.githubusercontent.com/fin-hq/fin-releases/main/install.ps1)))
```

No GitHub account or token is needed. The installer verifies the signed manifest and binary checksum before replacing an existing installation. It prints the install directory; add it to PATH if prompted.

Prebuilt binaries: Linux, macOS, and Windows on amd64 and arm64. Other architectures are not included.

## Start

```sh
fin init
fin serve
```

Use `fin status` for gateway, local usage and cached provider quotas; `fin status --refresh` explicitly refreshes quotas. `usage` shows local records; `quota` queries providers. Use `fin --help` for commands and `fin skill install` to install agent instructions.

## Providers

Use `fin provider presets` to see the products and authentication methods available in your binary. API keys and subscriptions remain separate credentials and quota scopes.

Live acceptance includes DeepSeek Flash, Kimi Coding CN, GLM Coding CN, Alibaba CN API and personal Token Plan paths, Gemini API Flash-Lite, and Antigravity OAuth Flash-Lite. Each product has its own verified protocol subset. Codex OAuth and Antigravity OAuth also passed native-backed image generation with decoded outputs and reconciled usage.

MiniMax, OpenRouter, TypeSafe Jev, Claude and Grok/xAI inference still need real-account acceptance. Gemini API image generation was blocked by the tested project's quota. Native image streaming and nonempty upstream thinking signatures require separate acceptance. Use the generated skill for precise boundaries.

## Managed credentials

`fin client add --managed` issues expiring task credentials with explicit routes, request limits and optional budgets. A coordinator can delegate bounded child credentials, rotate keys without resetting usage, and suspend or revoke access. Remote management is off by default. Use `fin client schema` and the generated skill for that binary's exact contract. API money budgets are configured estimates; subscription quotas are separate.

## Shared service

Serve one fin instance behind HTTPS and issue a separate, scoped key to each user. Account pools support explicit weights and quota-aware admission. Remote management is off by default; administer keys through the server CLI.

Back up configuration, credential files and runtime state together. Managed keys, usage, budgets and mutation receipts are not recreated by importing configuration alone. Multi-replica shared accounting is not supported.

## Upgrade

```sh
fin upgrade
```

Configuration and credentials are preserved. Installed, unmodified agent instructions are refreshed.

## Status

Early release. Linux installation and upgrades are verified; native macOS and Windows acceptance is pending. Cross-compilation alone does not verify runtime behavior.
