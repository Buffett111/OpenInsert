[CmdletBinding()]
param(
    [ValidateSet('win-x64', 'win-arm64')][string]$Runtime = 'win-x64',
    [ValidateSet('Debug', 'Release')][string]$Configuration = 'Release',
    [string]$Version
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$repoRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$project = Join-Path $repoRoot 'windows/OpenInsert.Windows/OpenInsert.Windows.csproj'
[xml]$projectXml = Get-Content -LiteralPath $project -Raw
$versionNode = $projectXml.SelectSingleNode('/Project/PropertyGroup/Version')
if ($null -eq $versionNode) { throw "Missing Version in $project" }
$projectVersion = $versionNode.InnerText.Trim()
if ([string]::IsNullOrWhiteSpace($Version)) { $Version = $projectVersion }
$Version = $Version -creplace '^v', ''
if ($Version -cnotmatch '^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)(?:-[0-9A-Za-z]+(?:[.-][0-9A-Za-z]+)*)?$') {
    throw 'Version must be major.minor.patch, optionally followed by a prerelease suffix (or prefixed with v).'
}
$numericVersion = ($Version -split '-', 2)[0]
$windowsBuildNode = $projectXml.SelectSingleNode('/Project/PropertyGroup/WindowsBuild')
$windowsBuild = if ($null -eq $windowsBuildNode) { '0' } else { $windowsBuildNode.InnerText.Trim() }
if ($windowsBuild -notmatch '^\d{1,5}$' -or [int]$windowsBuild -gt 65535) { throw 'WindowsBuild must be an integer from 0 to 65535.' }
if (@($numericVersion.Split('.') | Where-Object { [long]$_ -gt 65534 }).Count -gt 0) {
    throw 'Version components must be at most 65534 for a .NET assembly version.'
}
if ($Version -cne $projectVersion) {
    throw "Requested version $Version differs from project version $projectVersion. Update the project before packaging a release."
}
if ($env:OS -ne 'Windows_NT') { throw 'Build this Windows desktop application on Windows.' }
if (-not (Get-Command dotnet -ErrorAction SilentlyContinue)) {
    throw 'Install the .NET 10 SDK from https://dotnet.microsoft.com/download/dotnet/10.0, then reopen PowerShell.'
}

$outputRoot = [IO.Path]::GetFullPath((Join-Path $repoRoot 'dist/windows'))
$publishDirectory = [IO.Path]::GetFullPath((Join-Path $outputRoot "publish/$Runtime"))
# Clean only this architecture's generated publish directory. Refuse redirected
# ancestors so a junction cannot turn a local build cleanup into an external one.
if (-not $publishDirectory.StartsWith($outputRoot + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) {
    throw 'Publish directory is outside dist/windows.'
}
$candidate = $publishDirectory
while ($candidate -and $candidate.Length -ge $repoRoot.Length) {
    if (Test-Path -LiteralPath $candidate) {
        $item = Get-Item -LiteralPath $candidate -Force
        if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw "Refusing redirected build path: $candidate" }
    }
    if ($candidate -eq $repoRoot) { break }
    $candidate = Split-Path -Parent $candidate
}
if (Test-Path -LiteralPath $publishDirectory) { Remove-Item -LiteralPath $publishDirectory -Recurse -Force }
New-Item -ItemType Directory -Path $publishDirectory -Force | Out-Null

Push-Location $repoRoot
try {
    # A directory deployment keeps desktop resources explicit. Include the runtime
    # so recipients do not need an SDK or a separately installed .NET runtime.
    & dotnet publish $project --configuration $Configuration --runtime $Runtime --self-contained true --output $publishDirectory `
        '-p:PublishSingleFile=false' '-p:PublishTrimmed=false' '-p:DebugType=None' '-p:DebugSymbols=false' `
        "-p:Version=$Version" "-p:AssemblyVersion=$numericVersion.0" "-p:FileVersion=$numericVersion.$windowsBuild"
    if ($LASTEXITCODE -ne 0) { throw "dotnet publish failed ($LASTEXITCODE)." }
    foreach ($required in @('OpenInsert.exe', 'OpenInsert.dll', 'OpenInsert.runtimeconfig.json', 'hostfxr.dll', 'coreclr.dll')) {
        if (-not (Test-Path -LiteralPath (Join-Path $publishDirectory $required))) { throw "Publish output is missing $required" }
    }
    Copy-Item -LiteralPath (Join-Path $repoRoot 'LICENSE') -Destination (Join-Path $publishDirectory 'LICENSE.txt')
    Copy-Item -LiteralPath (Join-Path $repoRoot 'docs/WINDOWS.md') -Destination (Join-Path $publishDirectory 'WINDOWS.md')
    [ordered]@{ version = $Version; windowsBuild = [int]$windowsBuild; runtime = $Runtime; selfContained = $true } |
        ConvertTo-Json | Set-Content -LiteralPath (Join-Path $publishDirectory 'build-info.json') -Encoding UTF8
    Write-Host "Built $publishDirectory ($Version, self-contained)."
} finally {
    Pop-Location
}
