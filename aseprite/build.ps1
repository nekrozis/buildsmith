New-Item -ItemType Directory -Force pkgdir | Out-Null
Set-Location pkgdir

Remove-Item -Recurse -Force "C:\Program Files\OpenSSL\" 

New-Item -ItemType Directory -Force skia | Out-Null

curl.exe -L `
  "https://github.com/aseprite/skia/releases/download/m124-08a5439a6b/Skia-Windows-Release-x64.zip" `
  -o "Skia-Windows-Release-x64.zip"

7z x Skia-Windows-Release-x64.zip -o"skia"

git.exe clone --branch "v$env:pkgver" `
  https://github.com/aseprite/aseprite.git `
  --recurse-submodules

Set-Location aseprite

$env:CL = "/fp:fast"
$env:_CL_ = "/arch:AVX2"

$env:CFLAGS = "/O2 /Ob2 /GL /MT /DNDEBUG"
$env:CXXFLAGS = $env:CFLAGS

$env:_LINK_ = "/LTCG /INCREMENTAL:NO /OPT:REF,ICF /Brepro"

New-Item -ItemType Directory -Force build | Out-Null
Set-Location build

$SKIA_ROOT = (Resolve-Path "..\..\skia").Path
Write-Host "SKIA_ROOT=$SKIA_ROOT"

cmake.exe -G Ninja `
  -DCMAKE_BUILD_TYPE:STRING="None" `
  -DLAF_BACKEND:STRING="skia" `
  -DENABLE_SENTRY:BOOL=OFF `
  -DENABLE_NEWS:BOOL=OFF `
  -DENABLE_UPDATER:BOOL=OFF `
  -DENABLE_DRM:BOOL=OFF `
  -DENABLE_CCACHE:BOOL=OFF `
  -DSKIA_DIR:PATH="$SKIA_ROOT" `
  -DSKIA_LIBRARY_DIR:PATH="$SKIA_ROOT/out/Release-x64" `
  -DSKIA_LIBRARY:PATH="$SKIA_ROOT/out/Release-x64/skia.lib" `
  ..

cmake.exe --build .

Set-Location ..

New-Item -ItemType Directory -Force release | Out-Null
Set-Location release

Copy-Item "..\aseprite\build\bin\aseprite.exe" .
Copy-Item "..\aseprite\build\bin\data" -Recurse -Force