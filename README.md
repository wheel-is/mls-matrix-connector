# MLSListings Matrix one-command installer

This repository contains the Windows PowerShell bootstrap and the release workflow for `mls-matrix-node-v0.1.2.zip`.

## Install on Windows

Fully quit Claude Desktop. Open **Windows PowerShell**, paste this entire command, and press Enter:

```powershell
$p = Join-Path $env:TEMP 'install-mls-matrix.ps1'; [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12; Invoke-WebRequest -UseBasicParsing 'https://raw.githubusercontent.com/wheel-is/mls-matrix-connector/edcefc72fdf6d187448f783bef2b2413e17e54e5/install-mls-matrix.ps1' -OutFile $p; if ((Get-FileHash -LiteralPath $p -Algorithm SHA256).Hash -ne 'EE00EB062751F51F521F55E51D72C682C0D4C5CAEBE2E97D32F9FE358B48F759') { throw 'Installer checksum verification failed.' }; powershell.exe -NoProfile -ExecutionPolicy Bypass -File $p
```

The installer opens the MLS website in Edge or Chrome. Enter credentials and MFA only there. If the dashboard appears, click **Matrix Search** and allow the new Matrix tab to load.

The bootstrap:

- installs Node.js LTS through `winget` when Node 20+ is absent;
- downloads the versioned connector from the GitHub release;
- verifies the package SHA-256 before extraction;
- installs under `%LOCALAPPDATA%\MLSMatrixConnector`;
- runs the locked install, type check, offline tests, Windows DPAPI roundtrip, and build;
- backs up and safely merges `mcpServers.MLSListingsMatrix` into Claude Desktop's JSON config;
- opens the interactive MLS browser login without accepting credentials at the command line.

When setup completes, reopen Claude Desktop and ask: `Use MLSListings Matrix and call auth_status with probe true.`
