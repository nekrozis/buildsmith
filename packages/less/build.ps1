$ErrorActionPreference = 'Stop'

$source = Join-Path (Join-Path $env:PKG_SRC_DIR 'less') "less-$($env:PKG_PKGVER)"
if (-not (Test-Path $source)) { throw "source tree $source is missing" }
$build = Join-Path $env:PKG_WORK_DIR 'build'
New-Item -ItemType Directory -Force $build | Out-Null

zig version
if ($LASTEXITCODE -ne 0) { throw "zig failed with exit code $LASTEXITCODE" }

# Makefile.wnm's first rule: defines.wn is the hand-written Windows
# configuration. Without it less.h falls back to the Unix answers in
# defines.h.in and os.c includes <values.h>, which no Windows libc has.
Copy-Item -Path (Join-Path $source 'defines.wn') -Destination (Join-Path $source 'defines.h') -Force

# Same translation units as Makefile.wnm: help.c, funcs.h and lessmsg.inc are
# pre-generated in the release tarball, and lesskey_parse.c belongs to less.exe
# unless SECURE_COMPILE is defined.
$sources = @(
  'brac', 'ch', 'charset', 'cmdbuf', 'command', 'cvt', 'decode', 'edit',
  'evar', 'filename', 'forwback', 'help', 'ifile', 'input', 'jump',
  'lesskey_parse', 'line', 'linenum', 'lmsg', 'lsystem', 'main', 'mark',
  'optfunc', 'option', 'opttbl', 'os', 'output', 'pattern', 'position',
  'prompt', 'screen', 'search', 'signal', 'tags', 'ttyin', 'version', 'xbuf',
  'regexp'
)

# zig cc brings its own driver, libc and linker, so there is no vcvars, no
# Visual Studio and no mingw-w64 installation to pin: the compiler is one
# checksummed archive. -s is not cosmetic: without it zig passes its own debug
# and PDB flags to the linker and the debug identifier makes two builds of the
# same sources differ.
#
# -DMINGW selects upstream's own mingw branches in defines.wn (no <values.h>,
# a real unistd.h, a C99 snprintf) and -DUSE_REGEXP_C selects the vendored
# regexp.c, which is what Makefile.wnm gets by default and what makes search.c
# provide regerror(). Makefile.wnm sets neither because MSVC takes the other
# side of both #ifdefs; a mingw build without them compiles but cannot link.
$flags = @('-target', $env:ZIG_TARGET, "-mcpu=$($env:ZIG_CPU)", '-O2', '-DNDEBUG',
           '-DWIN32', '-D_CONSOLE', '-DMINGW', '-DUSE_REGEXP_C', '-I.')

Push-Location $source
try {
  $objects = @()
  foreach ($name in $sources) {
    $object = Join-Path $build "$name.o"
    zig cc @flags -c "$name.c" -o $object
    if ($LASTEXITCODE -ne 0) { throw "compiling $name.c failed with exit code $LASTEXITCODE" }
    $objects += $object
  }

  zig cc @flags -s -o (Join-Path $build 'less.exe') @objects -luser32 -lshell32
  if ($LASTEXITCODE -ne 0) { throw "linking less.exe failed with exit code $LASTEXITCODE" }
} finally {
  Pop-Location
}

New-Item -ItemType Directory -Force $env:PKG_OUT_DIR | Out-Null
Copy-Item -Path (Join-Path $build 'less.exe') -Destination $env:PKG_OUT_DIR