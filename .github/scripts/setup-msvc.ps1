<#
.SYNOPSIS
Exports the x64 MSVC build environment of the Visual Studio major release that
a recipe names in build.toolchain.msvc.

.DESCRIPTION
Only aseprite and ripgrep need a C/C++ compiler, and both ask for MSVC 17.
vswhere locates that install and vcvarsall.bat builds the environment; only the
variables it adds or changes are exported, so the runner image's own settings
survive and later steps still contribute to PATH.

Selecting by major version is the reason this is a script and not an action:
the recipe value is a bound, and an image that ships a second Visual Studio
release must not silently move the build to a newer toolset. The toolset patch
inside the release is expected to float with the image, which is why the script
logs it.

.PARAMETER Version
Visual Studio major version from the recipe, e.g. 17.

.PARAMETER Arch
Architecture passed to vcvarsall.bat. Every recipe here targets amd64v3, so the
default x64 is the only value in use.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string] $Version,

    [ValidateSet('x64', 'x86')]
    [string] $Arch = 'x64'
)

$ErrorActionPreference = 'Stop'

foreach ($name in 'GITHUB_ENV', 'GITHUB_PATH', 'RUNNER_TEMP') {
    if (-not (Test-Path -Path "Env:$name")) {
        throw "$name is not set; this script only runs inside a job"
    }
}

$vswhere = Join-Path -Path ${env:ProgramFiles(x86)} -ChildPath 'Microsoft Visual Studio\Installer\vswhere.exe'
if (-not (Test-Path -LiteralPath $vswhere)) {
    throw "vswhere.exe not found at $vswhere; the image has no Visual Studio installer"
}

# [17.0,18.0) keeps the pin: -latest then takes the newest patch of that major.
$range = '[{0}.0,{1}.0)' -f ([int] $Version), (([int] $Version) + 1)
$install = & $vswhere -latest -products * -version $range `
    -requires 'Microsoft.VisualStudio.Component.VC.Tools.x86.x64' -property installationPath
if ($LASTEXITCODE -ne 0) {
    throw "vswhere failed with exit code $LASTEXITCODE"
}
$install = @($install) | Where-Object { $_ } | Select-Object -First 1
if (-not $install) {
    throw "no Visual Studio $Version installation with the x64 C++ toolset is available"
}
$install = $install.Trim()

$vcvarsall = Join-Path -Path $install -ChildPath 'VC\Auxiliary\Build\vcvarsall.bat'
if (-not (Test-Path -LiteralPath $vcvarsall)) {
    throw "vcvarsall.bat not found in $install"
}

# vcvarsall.bat only changes its own cmd process, so the environment it prints
# is compared against this one and the difference exported. A wrapper file is
# used because the install path contains a space.
$before = @{}
Get-ChildItem -Path Env: | ForEach-Object { $before[$_.Name.ToUpperInvariant()] = [string] $_.Value }

$wrapper = Join-Path -Path $env:RUNNER_TEMP -ChildPath 'msvc-vcvars.cmd'
Set-Content -LiteralPath $wrapper -Encoding ascii -Value @(
    '@echo off'
    ('call "{0}" {1} >nul' -f $vcvarsall, $Arch)
    'if errorlevel 1 exit /b 1'
    'set'
)

$lines = & cmd.exe /d /c $wrapper
if ($LASTEXITCODE -ne 0) {
    throw "vcvarsall.bat $Arch failed with exit code $LASTEXITCODE"
}

$pairs = New-Object System.Collections.Generic.List[object]
foreach ($line in @($lines)) {
    if ($line -match '^([A-Za-z_][A-Za-z0-9_()#]*)=(.*)$') {
        $pairs.Add([pscustomobject]@{ Name = $Matches[1]; Value = $Matches[2] })
    }
}

$reported = @($pairs | ForEach-Object { $_.Name.ToUpperInvariant() })
foreach ($required in 'INCLUDE', 'LIB', 'PATH') {
    if ($reported -notcontains $required) {
        throw "vcvarsall.bat $Arch did not report $required"
    }
}

$exported = New-Object System.Collections.Generic.List[string]
foreach ($pair in $pairs) {
    if ($pair.Name -ieq 'PATH') {
        continue
    }
    $key = $pair.Name.ToUpperInvariant()
    if ($before.ContainsKey($key) -and $before[$key] -ceq $pair.Value) {
        continue
    }
    Add-Content -LiteralPath $env:GITHUB_ENV -Value ('{0}={1}' -f $pair.Name, $pair.Value)
    $exported.Add($pair.Name)
}

# vcvarsall prepends its directories to PATH; GITHUB_PATH prepends as well, so
# appending the new entries in order keeps that order ahead of the image's.
$newPath = ($pairs | Where-Object { $_.Name -ieq 'PATH' } | Select-Object -First 1).Value
$oldEntries = @($before['PATH'] -split ';' | Where-Object { $_ })
$added = @($newPath -split ';' | Where-Object { $_ } | Where-Object { $oldEntries -notcontains $_ })
if ($added.Count -gt 0) {
    Add-Content -LiteralPath $env:GITHUB_PATH -Value $added
}

$toolset = ($pairs | Where-Object { $_.Name -ieq 'VCToolsVersion' } | Select-Object -First 1).Value
if (-not $toolset) {
    $toolset = 'unknown'
}

Write-Host "MSVC $Version ($Arch), toolset $toolset, from $install"
Write-Host ("exported {0} variable(s): {1}" -f $exported.Count, ($exported -join ', '))
Write-Host ("prepended {0} PATH entry/entries" -f $added.Count)
