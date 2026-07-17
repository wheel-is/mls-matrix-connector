# MLSListings Matrix one-command installer

This directory contains the Windows PowerShell bootstrap intended to be uploaded alongside `mls-matrix-node-v0.1.1.zip` in the GitHub release `v0.1.1`.

The bootstrap:

- installs Node.js LTS through `winget` when Node 20+ is absent;
- downloads the versioned connector from the GitHub release;
- verifies the package SHA-256 before extraction;
- installs under `%LOCALAPPDATA%\MLSMatrixConnector`;
- runs the locked install, type check, offline tests, Windows DPAPI roundtrip, and build;
- backs up and safely merges `mcpServers.MLSListingsMatrix` into Claude Desktop's JSON config;
- opens the interactive MLS browser login without accepting credentials at the command line.

The public one-line command should download this script to `%TEMP%`, verify its release-published SHA-256, and run it with a process-scoped execution-policy bypass.

