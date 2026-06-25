set -euo pipefail

mkdir pkgdir && pushd pkgdir

rm -rf "C:/Program Files/OpenSSL/"

mkdir skia
curl -L 'https://github.com/aseprite/skia/releases/download/m124-08a5439a6b/Skia-Windows-Release-x64.zip' -o Skia-Windows-Release-x64.zip
7z x Skia-Windows-Release-x64.zip -o"skia"

git clone --branch v${pkgver} https://github.com/aseprite/aseprite.git --recurse-submodules
pushd aseprite

export CL="/fp:fast"
export _CL_="/arch:AVX2"

CFLAGS="/O2 /Ob2 /GL /MT /DNDEBUG"
CXXFLAGS="$CFLAGS"
export CFLAGS
export CXXFLAGS

export _LINK_="/LTCG /INCREMENTAL:NO /OPT:REF,ICF /Brepro"

mkdir build && cd build

cmake -G Ninja \
    -DCMAKE_BUILD_TYPE:STRING='Release' \
    -DLAF_BACKEND:STRING='skia' \
    -DENABLE_SENTRY:BOOL='OFF' \
    -DENABLE_NEWS:BOOL='OFF' \
    -DENABLE_UPDATER:BOOL='OFF' \
    -DENABLE_DRM:BOOL='OFF' \
    -DSKIA_DIR:PATH='../../skia' \
    -DSKIA_LIBRARY_DIR:PATH='../../skia/out/Release-x64' \
    -DSKIA_LIBRARY:PATH='../../skia/out/Release-x64/skia.lib' \
    ..

cmake --build . 

popd

mkdir release && cd release
cp ../aseprite/build/bin/aseprite.exe .
cp -r ../aseprite/build/bin/data .

