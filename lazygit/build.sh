set -euo pipefail

mkdir pkgdir

TARBALL="https://github.com/jesseduffield/lazygit/archive/v${pkgver}/lazygit-${pkgver}.tar.gz"

curl -L "$TARBALL" -o "lazygit-${pkgver}.tar.gz"
7z x "lazygit-${pkgver}.tar.gz"
7z x "lazygit-${pkgver}.tar" -o"pkgdir"

pushd pkgdir

cd "lazygit-${pkgver}"

go env 

SOURCE_DATE_EPOCH=$(
  gh release view v${pkgver} \
    --repo jesseduffield/lazygit \
    --json publishedAt --jq '.publishedAt' \
  | xargs -I{} date -d "{}" +%s
)

echo SOURCE_DATE_EPOCH=$SOURCE_DATE_EPOCH

go build -v -ldflags \
    " \
    -X main.date=$(date --date=@${SOURCE_DATE_EPOCH} -u +%Y-%m-%dT%H:%M:%SZ) \
    -X main.buildSource=binaryRelease \
    -X main.version=${pkgver} \
    -s -w \
    " \
    -o lazygit.exe

ls -alh
