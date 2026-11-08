$ErrorActionPreference = 'Stop'

Set-Location (Join-Path $env:PKG_SRC_DIR 'tools/gopls')

go version
if ($LASTEXITCODE -ne 0) { throw "go version failed with exit code $LASTEXITCODE" }

go build -v -o (Join-Path $env:PKG_OUT_DIR 'gopls.exe') .
if ($LASTEXITCODE -ne 0) { throw "go build failed with exit code $LASTEXITCODE" }