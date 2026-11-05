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

Use `fin --help` for commands and `fin skill install` to install agent instructions.

## Providers

Use `fin provider presets` to see available presets. Codex supports browser and device login; Kimi Coding CN supports device login and API keys. Moonshot uses separate API credentials.

DeepSeek Flash inference has passed live acceptance. Kimi login, automatic refresh, models and quota reads are verified; successful Kimi inference remains pending after the tested account reported exhausted quota and returned HTTP 429.

## Upgrade

```sh
fin upgrade
```

Configuration and credentials are preserved. Installed, unmodified agent instructions are refreshed.

## Status

Early release. Linux installation and upgrades are verified; native macOS and Windows acceptance is pending. Cross-compilation alone does not verify runtime behavior.
