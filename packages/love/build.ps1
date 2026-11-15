$ErrorActionPreference = 'Stop'

$loveRoot = Join-Path $env:PKG_SRC_DIR 'love'
$megaRoot = Join-Path $env:PKG_SRC_DIR 'megasource'
$luajitRoot = Join-Path $env:PKG_WORK_DIR 'luajit'
$buildRoot = Join-Path $env:PKG_WORK_DIR 'build'
$outBin = Join-Path $env:PKG_OUT_DIR 'bin'

# LuaJIT is built separately with its supplied build system, as upstream
# recommends. It gets the same base flags as the CMake targets, but not /GL
# or /LTCG: LuaJIT contains generated assembly and JIT code, and WPO has no
# upstream precedent there. Whole-program optimization is enabled for the
# CMake targets only.
$luajitSource = Join-Path $megaRoot 'libs/LuaJIT'
if (Test-Path $luajitRoot) { Remove-Item -Recurse -Force $luajitRoot }
Copy-Item -Recurse -Force $luajitSource $luajitRoot

$savedCl = $env:CL
$savedLink = $env:_LINK_
try {
  $env:CL = '/O2 /Ob2 /DNDEBUG /arch:AVX2'  # /MD comes from msvcbuild.bat
  Push-Location (Join-Path $luajitRoot 'src')
  try {
    cmd.exe /d /c 'msvcbuild.bat amalg'
    if ($LASTEXITCODE -ne 0) { throw "LuaJIT build failed with exit code $LASTEXITCODE" }
  } finally {
    Pop-Location
  }
} finally {
  $env:CL = $savedCl
  $env:_LINK_ = $savedLink
}

foreach ($name in @('lua51.dll', 'lua51.lib')) {
  $path = Join-Path (Join-Path $luajitRoot 'src') $name
  if (-not (Test-Path $path)) { throw "LuaJIT output $name is missing" }
  Copy-Item -LiteralPath $path -Destination $luajitRoot -Force
}

$luajitInclude = Join-Path $luajitRoot 'include'
New-Item -ItemType Directory -Force $luajitInclude | Out-Null
Get-ChildItem -Path (Join-Path $luajitRoot 'src') -Filter '*.h' | Copy-Item -Destination $luajitInclude -Force

# megasource has no prebuilt-LuaJIT option. The patch adds
# MEGA_LUAJIT_PREBUILT_DIR and a dummy luajit target; it does not touch any
# other dependency.
$patch = Join-Path $env:PKG_FILES_DIR 'megasource-luajit-prebuilt.patch'
$marker = Select-String -Path (Join-Path $megaRoot 'CMakeLists.txt') -Pattern 'MEGA_LUAJIT_PREBUILT_DIR' -SimpleMatch -Quiet
if (-not $marker) {
  git -C $megaRoot apply --whitespace=nowarn $patch
  if ($LASTEXITCODE -ne 0) { throw "megasource patch failed with exit code $LASTEXITCODE" }
}

New-Item -ItemType Directory -Force $buildRoot | Out-Null

# megasource 11.5 already builds the intended 2+2 split: SDL2, mpg123 and
# OpenAL Soft are shared; zlib, ogg, vorbis, theora, FreeType and libmodplug
# are static. LuaJIT is supplied as a prebuilt DLL from the step above.
# Do not run "cmake --install" or CPack here: LOVE_MSVC_DLLS would copy the
# Microsoft CRT into the archive.
cmake --version
if ($LASTEXITCODE -ne 0) { throw "cmake failed with exit code $LASTEXITCODE" }

$configure = @(
  '-G', 'Ninja',
  '-S', $megaRoot,
  '-B', $buildRoot,
  '-DCMAKE_BUILD_TYPE=Release',
  '-DCMAKE_MSVC_RUNTIME_LIBRARY=MultiThreadedDLL',
  '-DCMAKE_C_FLAGS_RELEASE=/MD /O2 /Ob2 /DNDEBUG /arch:AVX2 /GL',
  '-DCMAKE_CXX_FLAGS_RELEASE=/MD /O2 /Ob2 /DNDEBUG /arch:AVX2 /GL',
  '-DCMAKE_EXE_LINKER_FLAGS_RELEASE=/LTCG',
  '-DCMAKE_SHARED_LINKER_FLAGS_RELEASE=/LTCG',
  "-DMEGA_LOVE=$loveRoot",
  "-DMEGA_LUAJIT_PREBUILT_DIR=$luajitRoot",
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
foreach ($name in @('love.exe', 'lovec.exe', 'love.dll', 'SDL2.dll', 'OpenAL32.dll', 'mpg123.dll')) {
  Copy-Item -LiteralPath (Find-Output $name) -Destination $outBin -Force
}
Copy-Item -LiteralPath (Join-Path $luajitRoot 'lua51.dll') -Destination $outBin -Force

Copy-Item -LiteralPath (Join-Path $loveRoot 'license.txt') -Destination (Join-Path $env:PKG_OUT_DIR 'license.txt') -Force
