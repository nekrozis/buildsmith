$ErrorActionPreference = 'Stop'

Set-Location (Join-Path $env:PKG_SRC_DIR 'gdu')

$epoch = [DateTimeOffset]::FromUnixTimeSeconds([int64]$env:SOURCE_DATE_EPOCH).UtcDateTime
$buildTime = $epoch.ToString('yyyy-MM-ddTHH:mm:ss', [Globalization.CultureInfo]::InvariantCulture) + 'Z'

$pkg = 'github.com/dundee/gdu/v5/build'
$ldflags = "-s -w" +
    " -X $($pkg).Version=v$($env:PKG_PKGVER)" +
    " -X $($pkg).Time=$buildTime" +
    " -X $($pkg).User=buildsmith"

go version
if ($LASTEXITCODE -ne 0) { throw "go version failed with exit code $LASTEXITCODE" }

go build -v -ldflags $ldflags -o (Join-Path $env:PKG_OUT_DIR 'gdu.exe') ./cmd/gdu
if ($LASTEXITCODE -ne 0) { throw "go build failed with exit code $LASTEXITCODE" }