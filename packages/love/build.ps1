$ErrorActionPreference = 'Stop'

$loveRoot = Join-Path $env:PKG_SRC_DIR 'love'
$megaRoot = Join-Path $env:PKG_SRC_DIR 'megasource'
$buildRoot = Join-Path $env:PKG_WORK_DIR 'build'
$outBin = Join-Path $env:PKG_OUT_DIR 'bin'

New-Item -ItemType Directory -Force $buildRoot | Out-Null

# megasource 11.5 already builds the intended 2+2 split: LuaJIT, SDL2,
# mpg123 and OpenAL Soft are shared; zlib, ogg, vorbis, theora, FreeType
# and libmodplug are static. Do not run "cmake --install" or CPack here:
# LOVE_MSVC_DLLS would copy the Microsoft CRT into the archive.
cmake --version
if ($LASTEXITCODE -ne 0) { throw "cmake failed with exit code $LASTEXITCODE" }

$configure = @(
  '-G', 'Ninja',
  '-S', $megaRoot,
  '-B', $buildRoot,
  '-DCMAKE_BUILD_TYPE=Release',
  '-DCMAKE_MSVC_RUNTIME_LIBRARY=MultiThreadedDLL',
  '-DCMAKE_C_FLAGS_RELEASE=/MD /O2 /Ob2 /DNDEBUG /arch:AVX2',
  '-DCMAKE_CXX_FLAGS_RELEASE=/MD /O2 /Ob2 /DNDEBUG /arch:AVX2',
  "-DMEGA_LOVE=$loveRoot",
  '-DLOVE_JIT=ON',
  '-DLOVE_MPG123=ON'
)
& cmake @configure
if ($LASTEXITCODE -ne 0) { throw "cmake configure failed with exit code $LASTEXITCODE" }

& cmake --build $buildRoot --parallel
if ($LASTEXITCODE -ne 0) { throw "cmake build failed with exit code $LASTEXITCODE" }

function Find-Output([string] $name) {
  $found = @(Get-ChildItem -Path $buildRoot -Recurse -File -Filter $name |
    Where-Object { $_.FullName -notmatch '[\\/]CMakeFiles[\\/]' } |
    Sort-Object FullName)
  if ($found.Count -eq 0) { throw "build output $name not found under $buildRoot" }
  return $found[0].FullName
}

New-Item -ItemType Directory -Force $outBin | Out-Null
foreach ($name in @('love.exe', 'lovec.exe', 'love.dll', 'lua51.dll', 'SDL2.dll', 'OpenAL32.dll', 'mpg123.dll')) {
  Copy-Item -LiteralPath (Find-Output $name) -Destination $outBin -Force
}

Copy-Item -LiteralPath (Join-Path $loveRoot 'license.txt') -Destination (Join-Path $env:PKG_OUT_DIR 'license.txt') -Force
