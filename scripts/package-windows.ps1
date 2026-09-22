[CmdletBinding()]
param(
    [ValidateSet('win-x64', 'win-arm64')][string]$Runtime = 'win-x64',
    [ValidateSet('Debug', 'Release')][string]$Configuration = 'Release',
    [string]$Version,
    [switch]$Installer,
    [string]$InnoSetupCompiler
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$repoRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
& (Join-Path $PSScriptRoot 'build-windows.ps1') -Runtime $Runtime -Configuration $Configuration -Version $Version
$outputRoot = Join-Path $repoRoot 'dist/windows'
$publishDirectory = Join-Path $outputRoot "publish/$Runtime"
$buildInfo = Get-Content -LiteralPath (Join-Path $publishDirectory 'build-info.json') -Raw | ConvertFrom-Json
$Version = $buildInfo.version
$numericVersion = ($Version -split '-', 2)[0] + '.' + $buildInfo.windowsBuild
$architecture = $Runtime.Substring(4)
$stem = "OpenInsert-$Version-windows-$architecture"
$zipPath = Join-Path $outputRoot "$stem.zip"
$assetPaths = @($zipPath)

# Compress-Archive omits hidden files; .NET's ZIP writer includes every published
# file, including runtime resources. Extract the entire directory before launch.
Add-Type -AssemblyName System.IO.Compression.FileSystem
if (Test-Path -LiteralPath $zipPath) { Remove-Item -LiteralPath $zipPath -Force }
[IO.Compression.ZipFile]::CreateFromDirectory($publishDirectory, $zipPath, [IO.Compression.CompressionLevel]::Optimal, $true)

if ($Installer) {
    if ([string]::IsNullOrWhiteSpace($InnoSetupCompiler)) {
        $compilerCommand = Get-Command ISCC.exe -ErrorAction SilentlyContinue
        if ($compilerCommand) { $InnoSetupCompiler = $compilerCommand.Source }
        else {
            $candidates = @(
                (Join-Path ${env:ProgramFiles(x86)} 'Inno Setup 6/ISCC.exe'),
                (Join-Path $env:ProgramFiles 'Inno Setup 6/ISCC.exe'),
                (Join-Path $env:LOCALAPPDATA 'Programs/Inno Setup 6/ISCC.exe')
            )
            $InnoSetupCompiler = $candidates | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
        }
    }
    if ([string]::IsNullOrWhiteSpace($InnoSetupCompiler) -or -not (Test-Path -LiteralPath $InnoSetupCompiler)) {
        throw 'Inno Setup 6 is required for -Installer. Install it from https://jrsoftware.org/isdl.php or omit -Installer to build a portable ZIP.'
    }
    & $InnoSetupCompiler /Q "/DAppVersion=$Version" "/DAppVersionNumber=$numericVersion" "/DAppArchitecture=$architecture" "/DPublishDir=$publishDirectory" "/DOutputDir=$outputRoot" `
        (Join-Path $repoRoot 'windows/installer/OpenInsert.iss')
    if ($LASTEXITCODE -ne 0) { throw "Inno Setup failed ($LASTEXITCODE)." }
    $installerPath = Join-Path $outputRoot "$stem-setup.exe"
    if (-not (Test-Path -LiteralPath $installerPath)) { throw "Installer output missing: $installerPath" }
    $assetPaths += $installerPath
}

$checksums = foreach ($asset in $assetPaths) {
    '{0}  {1}' -f (Get-FileHash -LiteralPath $asset -Algorithm SHA256).Hash.ToLowerInvariant(), [IO.Path]::GetFileName($asset)
}
$checksums | Set-Content -LiteralPath (Join-Path $outputRoot "$stem-SHA256SUMS.txt") -Encoding ASCII
Write-Host "Packaged $($assetPaths -join ', ')"
