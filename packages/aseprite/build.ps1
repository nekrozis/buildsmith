$ErrorActionPreference = 'Stop'

$skiaRoot = Join-Path $env:PKG_SRC_DIR 'skia'
$sourceRoot = Join-Path $env:PKG_SRC_DIR 'aseprite'
$buildRoot = Join-Path $sourceRoot 'build'

Write-Host "SKIA_ROOT=$skiaRoot"
New-Item -ItemType Directory -Force $buildRoot | Out-Null

# The runner image ships an OpenSSL under C:/Program Files that CMake picks up
# no matter what the prefixes say, and the resulting exe imports
# libcrypto-*.dll, so it cannot start on a machine without that runtime. The
# old script deleted this tree before configuring and that is what worked; the
# runner is a throwaway VM, and the import check below fails the build if this
# ever stops being enough.
$systemOpenssl = Join-Path $env:ProgramFiles 'OpenSSL'
if (Test-Path $systemOpenssl) {
  Remove-Item -Recurse -Force $systemOpenssl
  Write-Host "removed $systemOpenssl"
}

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
    -DCMAKE_DISABLE_FIND_PACKAGE_OpenSSL:BOOL=TRUE `
    -DCMAKE_IGNORE_PREFIX_PATH="C:/Program Files/OpenSSL" `
    -DSKIA_DIR:PATH="$skiaRoot" `
    -DSKIA_LIBRARY_DIR:PATH="$skiaRoot/out/Release-x64" `
    -DSKIA_LIBRARY:PATH="$skiaRoot/out/Release-x64/skia.lib" `
    ..
  if ($LASTEXITCODE -ne 0) { throw "cmake configure failed with exit code $LASTEXITCODE" }

  cmake.exe --build . --parallel
  if ($LASTEXITCODE -ne 0) { throw "cmake build failed with exit code $LASTEXITCODE" }

  # The runner image ships an OpenSSL under C:/Program Files, and a build that
  # picks it up produces an exe importing libcrypto-*.dll: unstartable anywhere
  # else. Disabling the package should be enough, so treat a leftover import as
  # a bug in the configuration rather than a warning.
  $dependents = & dumpbin.exe /nologo /dependents (Join-Path $buildRoot 'bin/aseprite.exe')
  if ($LASTEXITCODE -ne 0) { throw "dumpbin failed with exit code $LASTEXITCODE" }
  $openssl = $dependents | Select-String -Pattern '(?i)\blib(ssl|crypto)[^\\/]*\.dll'
  if ($openssl) { throw "aseprite.exe imports OpenSSL: $($openssl -join '; ')" }
} finally {
  Pop-Location
}

New-Item -ItemType Directory -Force $env:PKG_OUT_DIR | Out-Null
Copy-Item (Join-Path $buildRoot 'bin/aseprite.exe') (Join-Path $env:PKG_OUT_DIR 'aseprite.exe')
Copy-Item (Join-Path $buildRoot 'bin/data') (Join-Path $env:PKG_OUT_DIR 'data') -Recurse -Force