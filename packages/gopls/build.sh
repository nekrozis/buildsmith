#!/usr/bin/env bash
set -euo pipefail

cd "$PKG_SRC_DIR/tools/gopls"

go version
go build -v -o "$PKG_OUT_DIR/gopls.exe" .