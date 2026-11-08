$ErrorActionPreference = 'Stop'

$skiaRoot = Join-Path $env:PKG_SRC_DIR 'skia'
$sourceRoot = Join-Path $env:PKG_SRC_DIR 'aseprite'
$buildRoot = Join-Path $sourceRoot 'build'

Write-Host "SKIA_ROOT=$skiaRoot"
New-Item -ItemType Directory -Force $buildRoot | Out-Null

Push-Location $buildRoot
try {
  cmake.exe -G Ninja `
    -DCMAKE_BUILD_TYPE:STRING="Release" `
    -DCMAKE_MSVC_RUNTIME_LIBRARY:STRING="MultiThreaded" `
    -DCMAKE_C_FLAGS_RELEASE:STRING="/O2 /Ob2 /DNDEBUG /arch:AVX2" `
    -DCMAKE_CXX_FLAGS_RELEASE:STRING="/O2 /Ob2 /DNDEBUG /arch:AVX2 /fp:fast" `
    -DLAF_BACKEND:STRING="skia" `
    -DENABLE_SENTRY:BOOL=OFF `
    -DENABLE_NEWS:BOOL=OFF `
    -DENABLE_UPDATER:BOOL=OFF `
    -DENABLE_DRM:BOOL=OFF `
    -DENABLE_CCACHE:BOOL=OFF `
    -DCMAKE_IGNORE_PREFIX_PATH="C:/Program Files/OpenSSL" `
    -DSKIA_DIR:PATH="$skiaRoot" `
    -DSKIA_LIBRARY_DIR:PATH="$skiaRoot/out/Release-x64" `
    -DSKIA_LIBRARY:PATH="$skiaRoot/out/Release-x64/skia.lib" `
    ..
  if ($LASTEXITCODE -ne 0) { throw "cmake configure failed with exit code $LASTEXITCODE" }

  cmake.exe --build . --parallel
  if ($LASTEXITCODE -ne 0) { throw "cmake build failed with exit code $LASTEXITCODE" }
} finally {
  Pop-Location
}

New-Item -ItemType Directory -Force $env:PKG_OUT_DIR | Out-Null
Copy-Item (Join-Path $buildRoot 'bin/aseprite.exe') (Join-Path $env:PKG_OUT_DIR 'aseprite.exe')
Copy-Item (Join-Path $buildRoot 'bin/data') (Join-Path $env:PKG_OUT_DIR 'data') -Recurse -Force