#!/usr/bin/env bash
set -euo pipefail

cd "$PKG_SRC_DIR/lazygit"

build_date="$(date -u -d "@${SOURCE_DATE_EPOCH}" +%Y-%m-%dT%H:%M:%SZ)"

go version
go build -v \
  -ldflags "-s -w -X main.version=${PKG_PKGVER} -X main.buildSource=binaryRelease -X main.date=${build_date}" \
  -o "$PKG_OUT_DIR/lazygit.exe" .