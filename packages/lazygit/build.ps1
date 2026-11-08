$ErrorActionPreference = 'Stop'

Set-Location (Join-Path $env:PKG_SRC_DIR 'lazygit')

$epoch = [DateTimeOffset]::FromUnixTimeSeconds([int64]$env:SOURCE_DATE_EPOCH).UtcDateTime
$buildDate = $epoch.ToString('yyyy-MM-ddTHH:mm:ss', [Globalization.CultureInfo]::InvariantCulture) + 'Z'
$ldflags = "-s -w -X main.version=$($env:PKG_PKGVER) -X main.buildSource=binaryRelease -X main.date=$buildDate"

go version
if ($LASTEXITCODE -ne 0) { throw "go version failed with exit code $LASTEXITCODE" }

go build -v -ldflags $ldflags -o (Join-Path $env:PKG_OUT_DIR 'lazygit.exe') .
if ($LASTEXITCODE -ne 0) { throw "go build failed with exit code $LASTEXITCODE" }