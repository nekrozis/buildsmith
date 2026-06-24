set -euo pipefail

mkdir pkgdir && pushd pkgdir

rm -rf "C:/Program Files/OpenSSL/"

mkdir skia
curl -L 'https://github.com/aseprite/skia/releases/download/m124-08a5439a6b/Skia-Windows-Release-x64.zip' -o Skia-Windows-Release-x64.zip
7z x Skia-Windows-Release-x64.zip -o"skia"

git clone --branch v${pkgver} https://github.com/aseprite/aseprite.git --recurse-submodules
pushd aseprite

sed -i '/CMAKE_USER_MAKE_RULES_OVERRIDE/d' CMakeLists.txt
sed -i '/CMAKE_USER_MAKE_RULES_OVERRIDE/d' laf/CMakeLists.txt

export _CL_="${_CL_} /D NDEBUG"

mkdir build && cd build

cmake -G Ninja \
    -DCMAKE_BUILD_TYPE=Release \
    -DLAF_BACKEND=skia \
    -DENABLE_SENTRY=OFF \
    -DENABLE_NEWS=OFF \
    -DENABLE_UPDATER=OFF \
    -DENABLE_DRM=OFF \
    -DSKIA_DIR=../../skia \
    -DSKIA_LIBRARY_DIR=../../skia/out/Release-x64 \
    -DSKIA_LIBRARY=../../skia/out/Release-x64/skia.lib \
    ..

cmake --build . 

popd

mkdir release && cd release
cp ../aseprite/build/bin/aseprite.exe .
cp -r ../aseprite/build/bin/data .

