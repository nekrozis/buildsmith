$ErrorActionPreference = 'Stop'

$loveRoot = Join-Path $env:PKG_SRC_DIR 'love'
$megaRoot = Join-Path $env:PKG_SRC_DIR 'megasource'
$luajitRoot = Join-Path $env:PKG_WORK_DIR 'luajit'
$buildRoot = Join-Path $env:PKG_WORK_DIR 'build'
$outBin = Join-Path $env:PKG_OUT_DIR 'bin'

# Map each leg's source/work root to a stable virtual path so __FILE__ and
# debug paths do not contain work/a or work/b.
$pathMap = "/pathmap:$env:PKG_SRC_DIR=/_/src /pathmap:$env:PKG_WORK_DIR=/_/work"

# LuaJIT is built separately, outside CMake, from the openresty/luajit2
# commit pinned in the recipe (the tree Debian stable ships) and injected as
# a prebuilt library. The compiler is zig cc, not MSVC: this was the last
# non-reproducible file in the package. MSVC's backend picks different but
# equivalent instruction encodings for the same input across runs, and no
# /Brepro, /pathmap or /experimental:deterministic setting changes that.
$luajitSource = Join-Path $env:PKG_SRC_DIR 'luajit'
if (Test-Path $luajitRoot) { Remove-Item -Recurse -Force $luajitRoot }
Copy-Item -Recurse -Force $luajitSource $luajitRoot

# The fork ships .relver as an unexpanded $Format:%ct$ placeholder, so the
# version string has to come from the pinned commit. pkgctl keeps .git, and a
# shallow clone still answers this for the checked-out commit.
$luajitRelver = (& git -C $luajitSource show -s --format=%ct HEAD).Trim()
if ($LASTEXITCODE -ne 0) { throw "cannot read the LuaJIT commit time" }

$zig = @('-target', $env:ZIG_TARGET, "-mcpu=$($env:ZIG_CPU)", '-O2', '-DNDEBUG')
$luajitSrc = Join-Path $luajitRoot 'src'
Push-Location $luajitSrc
try {
  # Same steps as msvcbuild.bat: host minilua, dynasm, version header,
  # buildvm, generated VM object, amalgamated library, DLL.
  & zig cc @zig -o minilua.exe 'host/minilua.c'
  if ($LASTEXITCODE -ne 0) { throw "LuaJIT minilua failed with exit code $LASTEXITCODE" }

  & ./minilua.exe '..\dynasm\dynasm.lua' -LN -D WIN -D JIT -D FFI -D ENDIAN_LE -D FPU -D P64 -o 'host\buildvm_arch.h' 'vm_x64.dasc'
  if ($LASTEXITCODE -ne 0) { throw "LuaJIT dynasm failed with exit code $LASTEXITCODE" }

  Set-Content -Path 'luajit_relver.txt' -Value $luajitRelver -NoNewline
  & ./minilua.exe 'host\genversion.lua'
  if ($LASTEXITCODE -ne 0) { throw "LuaJIT genversion failed with exit code $LASTEXITCODE" }

  $hostSources = @(Get-ChildItem -Path 'host' -Filter 'buildvm*.c' | ForEach-Object FullName)
  & zig cc @zig -I . -I '..\dynasm' -o buildvm.exe @hostSources
  if ($LASTEXITCODE -ne 0) { throw "LuaJIT buildvm failed with exit code $LASTEXITCODE" }

  $libSources = @('lib_base.c', 'lib_math.c', 'lib_bit.c', 'lib_string.c',
                  'lib_table.c', 'lib_io.c', 'lib_os.c', 'lib_package.c',
                  'lib_debug.c', 'lib_jit.c', 'lib_ffi.c', 'lib_buffer.c')

  & ./buildvm.exe -m peobj -o 'lj_vm.obj'
  if ($LASTEXITCODE -ne 0) { throw "LuaJIT peobj failed with exit code $LASTEXITCODE" }
  foreach ($mode in @(@('bcdef', 'lj_bcdef.h'), @('ffdef', 'lj_ffdef.h'),
                      @('libdef', 'lj_libdef.h'), @('recdef', 'lj_recdef.h'))) {
    & ./buildvm.exe -m $mode[0] -o $mode[1] @libSources
    if ($LASTEXITCODE -ne 0) { throw "LuaJIT $($mode[0]) failed with exit code $LASTEXITCODE" }
  }
  & ./buildvm.exe -m vmdef -o 'jit\vmdef.lua' @libSources
  if ($LASTEXITCODE -ne 0) { throw "LuaJIT vmdef failed with exit code $LASTEXITCODE" }
  & ./buildvm.exe -m folddef -o 'lj_folddef.h' 'lj_opt_fold.c'
  if ($LASTEXITCODE -ne 0) { throw "LuaJIT folddef failed with exit code $LASTEXITCODE" }

  & zig cc @zig -DLUA_BUILD_AS_DLL -c 'ljamalg.c' -o 'ljamalg.o'
  if ($LASTEXITCODE -ne 0) { throw "LuaJIT amalgamation failed with exit code $LASTEXITCODE" }
  & zig cc @zig -shared -s -o 'lua51.dll' 'ljamalg.o' 'lj_vm.obj'
  if ($LASTEXITCODE -ne 0) { throw "LuaJIT link failed with exit code $LASTEXITCODE" }

  # The MSVC-built love.dll and the two exes link against an import library.
  # zig usually emits one; fall back to building it from the DLL exports.
  if (-not (Test-Path 'lua51.lib')) {
    $exports = & dumpbin /nologo /exports 'lua51.dll' | ForEach-Object {
      if ($_ -match '^\s+\d+\s+[0-9A-Fa-f]+\s+[0-9A-Fa-f]+\s+(\S+)$') { $matches[1] }
    }
    if (-not $exports) { throw "cannot extract LuaJIT exports from lua51.dll" }
    Set-Content -Path 'lua51.def' -Value (@('LIBRARY lua51', 'EXPORTS') + $exports) -Encoding ascii
    & lib /nologo /def:lua51.def /machine:x64 /out:lua51.lib
    if ($LASTEXITCODE -ne 0) { throw "LuaJIT import library failed with exit code $LASTEXITCODE" }
  }
} finally {
  Pop-Location
}

foreach ($name in @('lua51.dll', 'lua51.lib')) {
  $path = Join-Path $luajitSrc $name
  if (-not (Test-Path $path)) { throw "LuaJIT output $name is missing" }
  Copy-Item -LiteralPath $path -Destination $luajitRoot -Force
}

$luajitInclude = Join-Path $luajitRoot 'include'
New-Item -ItemType Directory -Force $luajitInclude | Out-Null
Get-ChildItem -Path (Join-Path $luajitRoot 'src') -Filter '*.h' | Copy-Item -Destination $luajitInclude -Force

# megasource has no prebuilt-LuaJIT option. The first patch adds
# MEGA_LUAJIT_PREBUILT_DIR and a dummy luajit target; the second lets
# OpenAL's build-time native-tools configure run under CMake 4.x.
$patches = @(
  @{ Path = 'megasource-luajit-prebuilt.patch'; Marker = 'MEGA_LUAJIT_PREBUILT_DIR'; File = 'CMakeLists.txt' },
  @{ Path = 'openal-native-tools-cmake.patch'; Marker = 'cmake_minimum_required(VERSION 3.5)'; File = 'libs/openal-soft/native-tools/CMakeLists.txt' }
)
foreach ($item in $patches) {
  $marker = Select-String -Path (Join-Path $megaRoot $item.File) -Pattern $item.Marker -SimpleMatch -Quiet
  if (-not $marker) {
    $patch = Join-Path $env:PKG_FILES_DIR $item.Path
    git -C $megaRoot apply --whitespace=nowarn $patch
    if ($LASTEXITCODE -ne 0) { throw "patch $($item.Path) failed with exit code $LASTEXITCODE" }
  }
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
  # The 11.5 dependency tree still declares CMake 2.8/3.x minimums;
  # CMake 4.x rejects <3.5 unless this opt-in is set.
  '-DCMAKE_POLICY_VERSION_MINIMUM=3.5',
  '-DCMAKE_MSVC_RUNTIME_LIBRARY=MultiThreadedDLL',
  "-DCMAKE_C_FLAGS_RELEASE=/MD /O2 /Ob2 /DNDEBUG /arch:AVX2 /GL /Brepro /experimental:deterministic $pathMap",
  "-DCMAKE_CXX_FLAGS_RELEASE=/MD /O2 /Ob2 /DNDEBUG /arch:AVX2 /GL /Brepro /experimental:deterministic $pathMap",
  '-DCMAKE_STATIC_LINKER_FLAGS_RELEASE=/Brepro',
  '-DCMAKE_EXE_LINKER_FLAGS_RELEASE=/LTCG /experimental:deterministic /PDBALTPATH:%_PDB%',
  '-DCMAKE_SHARED_LINKER_FLAGS_RELEASE=/LTCG /experimental:deterministic /PDBALTPATH:%_PDB%',
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

# --version returns before a lua_State exists, so the recipe's smoke never
# calls into lua51.dll. Run a tiny headless game here instead: love.exe (MSVC)
# creates the state through the zig-built DLL, loads the FFI and quits. Window,
# graphics and audio modules are off, so this works without a GPU or a device.
$smokeDir = Join-Path $env:PKG_WORK_DIR 'smoke'
New-Item -ItemType Directory -Force $smokeDir | Out-Null
@'
function love.conf(t)
  t.modules.audio = false
  t.modules.graphics = false
  t.modules.joystick = false
  t.modules.physics = false
  t.modules.sound = false
  t.modules.video = false
  t.modules.window = false
end
'@ | Set-Content -Path (Join-Path $smokeDir 'conf.lua') -Encoding ascii
@'
function love.load()
  local ffi = require("ffi")
  print("runtime " .. _VERSION .. " / " .. jit.version .. " / ffi " .. tostring(ffi ~= nil))
  love.event.quit(0)
end
'@ | Set-Content -Path (Join-Path $smokeDir 'main.lua') -Encoding ascii
& (Join-Path $outBin 'love.exe') $smokeDir
if ($LASTEXITCODE -ne 0) { throw "LuaJIT cross-CRT runtime check failed with exit code $LASTEXITCODE" }

Copy-Item -LiteralPath (Join-Path $loveRoot 'license.txt') -Destination (Join-Path $env:PKG_OUT_DIR 'license.txt') -Force
