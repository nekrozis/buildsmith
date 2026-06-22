mkdir pkgdir

TARBALL="https://github.com/golang/tools/archive/gopls/v${pkgver}.tar.gz"

curl -L "$TARBALL" -o "gopls-${pkgver}.tar.gz"
tar xvf gopls-${pkgver}.tar.gz -C pkgdir

pushd pkgdir

cd "tools-gopls-v${pkgver}/gopls"

go env 

go build -v -ldflags '-s -w' -o gopls.exe

ls -alh
