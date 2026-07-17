[CmdletBinding()]
param(
    [string]$PackageUrl = "https://github.com/wheel-is/mls-matrix-connector/releases/download/v0.1.2/mls-matrix-node-v0.1.2.zip",
    [string]$ExpectedPackageSha256 = "362256786494ECB2A750CBC37F7291A7D13041D02011B516E07DC0961065C52C",
    [string]$InstallRoot = (Join-Path $env:LOCALAPPDATA "MLSMatrixConnector"),
    [switch]$SkipLogin
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"

function Write-Step {
    param([string]$Message)
    Write-Host ""
    Write-Host "==> $Message" -ForegroundColor Cyan
}

function Invoke-CheckedCommand {
    param(
        [string]$FilePath,
        [string[]]$ArgumentList,
        [string]$Description
    )

    & $FilePath @ArgumentList | Out-Host
    $ExitCode = $LASTEXITCODE
    if ($ExitCode -ne 0) {
        throw "$Description failed with exit code $ExitCode."
    }
}

function Refresh-ProcessPath {
    $MachinePath = [Environment]::GetEnvironmentVariable("Path", "Machine")
    $UserPath = [Environment]::GetEnvironmentVariable("Path", "User")
    $env:Path = "$MachinePath;$UserPath"
}

function Find-NodeInstallation {
    $Candidates = @()
    $PathNode = Get-Command node.exe -ErrorAction SilentlyContinue
    if ($PathNode) {
        $Candidates += $PathNode.Source
    }
    if ($env:ProgramFiles) {
        $Candidates += (Join-Path $env:ProgramFiles "nodejs\node.exe")
    }
    if (${env:ProgramFiles(x86)}) {
        $Candidates += (Join-Path ${env:ProgramFiles(x86)} "nodejs\node.exe")
    }
    if ($env:LOCALAPPDATA) {
        $Candidates += (Join-Path $env:LOCALAPPDATA "Programs\nodejs\node.exe")
    }

    foreach ($Candidate in ($Candidates | Select-Object -Unique)) {
        if (-not (Test-Path -LiteralPath $Candidate -PathType Leaf)) {
            continue
        }
        $VersionOutput = @(& $Candidate --version 2>$null)
        $VersionExitCode = $LASTEXITCODE
        if ($VersionExitCode -ne 0 -or $VersionOutput.Count -eq 0) {
            continue
        }
        $VersionText = ($VersionOutput -join "").Trim()
        if ($VersionText -notmatch '^v([0-9]+)\.' -or [int]$Matches[1] -lt 20) {
            continue
        }
        $NodeDirectory = Split-Path -Parent $Candidate
        $NpmPath = Join-Path $NodeDirectory "npm.cmd"
        if (-not (Test-Path -LiteralPath $NpmPath -PathType Leaf)) {
            continue
        }
        return [pscustomobject]@{
            NodePath = $Candidate
            NpmPath = $NpmPath
            Version = $VersionText
        }
    }
    return $null
}

function Get-NodeInstallation {
    $Installation = Find-NodeInstallation
    if ($Installation) {
        return $Installation
    }

    Write-Step "Installing Node.js LTS"
    $WingetCommand = Get-Command winget.exe -ErrorAction SilentlyContinue
    if (-not $WingetCommand) {
        throw "Node.js 20 or newer is required, and Windows Package Manager (winget) was not found. Install Node.js LTS from https://nodejs.org/ and run this command again."
    }

    $WingetArguments = @(
        "install",
        "--id", "OpenJS.NodeJS.LTS",
        "--exact",
        "--source", "winget",
        "--silent",
        "--accept-source-agreements",
        "--accept-package-agreements",
        "--disable-interactivity"
    )
    & $WingetCommand.Source @WingetArguments | Out-Host
    $WingetExitCode = $LASTEXITCODE

    Refresh-ProcessPath
    $Installation = Find-NodeInstallation
    if (-not $Installation) {
        throw "Node.js 20 or newer could not be found after winget finished with exit code $WingetExitCode. Install Node.js LTS from https://nodejs.org/ and run this command again."
    }
    return $Installation
}

function Merge-ClaudeDesktopConfig {
    param(
        [string]$NodePath,
        [string]$ServerPath
    )

    $ClaudeDirectory = Join-Path $env:APPDATA "Claude"
    $ConfigPath = Join-Path $ClaudeDirectory "claude_desktop_config.json"
    [void](New-Item -ItemType Directory -Path $ClaudeDirectory -Force)

    $BackupPath = ""
    $ConfigExisted = Test-Path -LiteralPath $ConfigPath
    if ($ConfigExisted) {
        $Timestamp = Get-Date -Format "yyyyMMdd-HHmmssfff"
        $BackupSuffix = [Guid]::NewGuid().ToString("N").Substring(0, 8)
        $BackupPath = "$ConfigPath.backup-$Timestamp-$BackupSuffix"
        Copy-Item -LiteralPath $ConfigPath -Destination $BackupPath
        $RawConfig = [IO.File]::ReadAllText($ConfigPath)
        if ([string]::IsNullOrWhiteSpace($RawConfig)) {
            $Config = [pscustomobject]@{}
        }
        else {
            try {
                $Config = $RawConfig | ConvertFrom-Json
            }
            catch {
                throw "Claude Desktop config is not valid JSON. Its untouched backup is at $BackupPath."
            }
        }
    }
    else {
        $Config = [pscustomobject]@{}
    }

    if ($null -eq $Config -or $Config -isnot [System.Management.Automation.PSCustomObject]) {
        throw "Claude Desktop config must contain a JSON object. The original file was not changed."
    }

    $ServersProperty = $Config.PSObject.Properties["mcpServers"]
    if ($null -eq $ServersProperty) {
        $Config | Add-Member -MemberType NoteProperty -Name "mcpServers" -Value ([pscustomobject]@{})
    }
    elseif ($null -eq $ServersProperty.Value) {
        $Config.mcpServers = [pscustomobject]@{}
    }
    elseif ($ServersProperty.Value -isnot [pscustomobject]) {
        throw "Claude Desktop config has an unexpected mcpServers value. Its untouched backup is at $BackupPath."
    }

    $Server = [pscustomobject][ordered]@{
        command = $NodePath
        args = @($ServerPath)
    }
    $Config.mcpServers | Add-Member `
        -MemberType NoteProperty `
        -Name "MLSListingsMatrix" `
        -Value $Server `
        -Force

    $Json = $Config | ConvertTo-Json -Depth 100
    $TemporaryConfigPath = Join-Path $ClaudeDirectory ("claude_desktop_config.json.tmp-" + [Guid]::NewGuid().ToString("N"))
    $Utf8WithoutBom = New-Object System.Text.UTF8Encoding($false)
    try {
        [IO.File]::WriteAllText($TemporaryConfigPath, "$Json`r`n", $Utf8WithoutBom)
        if ($ConfigExisted) {
            [IO.File]::Replace($TemporaryConfigPath, $ConfigPath, $null, $true)
        }
        else {
            [IO.File]::Move($TemporaryConfigPath, $ConfigPath)
        }
    }
    finally {
        if (Test-Path -LiteralPath $TemporaryConfigPath) {
            Remove-Item -LiteralPath $TemporaryConfigPath -Force -ErrorAction SilentlyContinue
        }
    }

    return $BackupPath
}

if ($env:OS -ne "Windows_NT") {
    throw "This installer is only for Windows."
}

$PackageUri = [Uri]$PackageUrl
if ($PackageUri.Scheme -ne "https" -or $PackageUri.Host -ne "github.com") {
    throw "Refusing a package URL that is not HTTPS on github.com."
}

$RunningClaude = Get-Process -Name "Claude*" -ErrorAction SilentlyContinue
if ($RunningClaude) {
    Write-Host "Claude Desktop is currently running." -ForegroundColor Yellow
    Write-Host "Fully quit Claude Desktop from the system tray, then return here."
    [void](Read-Host "Press Enter after Claude Desktop is closed")
    if (Get-Process -Name "Claude*" -ErrorAction SilentlyContinue) {
        throw "Claude Desktop is still running. Fully quit it from the system tray and rerun the installer."
    }
}

$NodeInstallation = Get-NodeInstallation
$NodePath = $NodeInstallation.NodePath
$NpmPath = $NodeInstallation.NpmPath
$NodeDirectory = Split-Path -Parent $NodePath
$env:Path = "$NodeDirectory;$env:Path"
Write-Host "Using Node.js $($NodeInstallation.Version) from $NodePath"

Write-Step "Downloading MLSListings Matrix connector v0.1.2"
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$TemporaryRoot = Join-Path $env:LOCALAPPDATA ("MLSMatrixConnector-Staging-" + [Guid]::NewGuid().ToString("N"))
$ZipPath = Join-Path $TemporaryRoot "mls-matrix-node-v0.1.2.zip"
$ExtractPath = Join-Path $TemporaryRoot "extracted"
[void](New-Item -ItemType Directory -Path $TemporaryRoot -Force)
$InstallBackupPath = ""

try {
    Invoke-WebRequest `
        -Uri $PackageUrl `
        -OutFile $ZipPath `
        -UseBasicParsing `
        -Headers @{ "User-Agent" = "MLSMatrixConnectorInstaller/0.1.2" }

    $ActualHash = (Get-FileHash -LiteralPath $ZipPath -Algorithm SHA256).Hash.ToUpperInvariant()
    if ($ActualHash -ne $ExpectedPackageSha256.ToUpperInvariant()) {
        throw "Downloaded package checksum did not match. Refusing to install it."
    }

    Write-Step "Extracting the verified connector"
    Expand-Archive -LiteralPath $ZipPath -DestinationPath $ExtractPath -Force
    $SourceRoot = Join-Path $ExtractPath "mls-matrix-node"
    if (-not (Test-Path -LiteralPath (Join-Path $SourceRoot "package-lock.json"))) {
        throw "The verified package did not contain the expected connector folder."
    }

    Push-Location $SourceRoot
    try {
        Write-Step "Installing locked connector dependencies"
        Invoke-CheckedCommand -FilePath $NpmPath -ArgumentList @("ci") -Description "Dependency installation"

        Write-Step "Checking and testing the connector"
        Invoke-CheckedCommand -FilePath $NpmPath -ArgumentList @("run", "check") -Description "TypeScript check"
        Invoke-CheckedCommand -FilePath $NpmPath -ArgumentList @("test") -Description "Offline and Windows DPAPI tests"

        Write-Step "Building the Claude connector"
        Invoke-CheckedCommand -FilePath $NpmPath -ArgumentList @("run", "build") -Description "Connector build"
    }
    finally {
        Pop-Location
    }

    Write-Step "Promoting the verified connector installation"
    $InstallParent = Split-Path -Parent $InstallRoot
    [void](New-Item -ItemType Directory -Path $InstallParent -Force)
    if (Test-Path -LiteralPath $InstallRoot) {
        $InstallTimestamp = Get-Date -Format "yyyyMMdd-HHmmssfff"
        $InstallBackupSuffix = [Guid]::NewGuid().ToString("N").Substring(0, 8)
        $InstallBackupPath = "$InstallRoot.backup-$InstallTimestamp-$InstallBackupSuffix"
        Move-Item -LiteralPath $InstallRoot -Destination $InstallBackupPath
    }
    try {
        Move-Item -LiteralPath $SourceRoot -Destination $InstallRoot
    }
    catch {
        $PromotionError = $_
        if ($InstallBackupPath -and
            (Test-Path -LiteralPath $InstallBackupPath) -and
            -not (Test-Path -LiteralPath $InstallRoot)) {
            Move-Item -LiteralPath $InstallBackupPath -Destination $InstallRoot
        }
        throw $PromotionError
    }
}
finally {
    if (Test-Path -LiteralPath $TemporaryRoot) {
        Remove-Item -LiteralPath $TemporaryRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Write-Step "Connecting the server to Claude Desktop"
if (Get-Process -Name "Claude*" -ErrorAction SilentlyContinue) {
    throw "Claude Desktop was reopened during setup. Fully quit it from the system tray and rerun the installer."
}
$ServerPath = Join-Path $InstallRoot "dist\mcp-server.js"
$BackupPath = Merge-ClaudeDesktopConfig -NodePath $NodePath -ServerPath $ServerPath
if ($BackupPath) {
    Write-Host "Existing Claude config backed up to: $BackupPath"
}
if ($InstallBackupPath) {
    Write-Host "Previous connector installation backed up to: $InstallBackupPath"
}

if (-not $SkipLogin) {
    Write-Step "Opening the secure MLS login"
    Write-Host "Enter the username, password, and MFA only in the MLS website."
    Write-Host "If the dashboard appears, click Matrix Search. A new tab is expected."
    $CliPath = Join-Path $InstallRoot "dist\cli.js"
    Invoke-CheckedCommand -FilePath $NodePath -ArgumentList @($CliPath, "login") -Description "MLS browser login"
}

Write-Host ""
Write-Host "Setup complete." -ForegroundColor Green
Write-Host "Open Claude Desktop and ask: Use MLSListings Matrix and call auth_status with probe true."
