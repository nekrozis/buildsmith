$ErrorActionPreference = 'Stop'

$tectonicRoot = Join-Path $env:PKG_SRC_DIR 'tectonic'
Set-Location $tectonicRoot

Remove-Item -Recurse -Force '.cargo' -ErrorAction SilentlyContinue
Remove-Item -Force 'rust-toolchain.toml' -ErrorAction SilentlyContinue

# HarfBuzz is a submodule upstream. The recipe fetches it as a separate source,
# so put it where crates/bridge_harfbuzz/build.rs looks for it.
$harfbuzzTarget = Join-Path $tectonicRoot 'crates/bridge_harfbuzz/harfbuzz'
New-Item -ItemType Directory -Force $harfbuzzTarget | Out-Null
Copy-Item -Path (Join-Path $env:PKG_SRC_DIR 'harfbuzz/*') -Destination $harfbuzzTarget -Recurse -Force

@'

[profile.make]
inherits = "release"
opt-level = 3
debug = false
strip = "debuginfo"
debug-assertions = false
overflow-checks = false
lto = "thin"
panic = "unwind"
incremental = false
codegen-units = 1
rpath = false
'@ | Add-Content -Path 'Cargo.toml' -Encoding utf8NoBOM

$env:RUSTFLAGS = "-C target-cpu=x86-64-v3 " +
  "--remap-path-prefix=$env:PKG_SRC_DIR=/_/src " +
  "--remap-path-prefix=$env:PKG_WORK_DIR=/_/work"
$env:_CL_ = "/arch:AVX2 /O2 /Ob2 /DNDEBUG /Brepro " +
  "/pathmap:$env:PKG_SRC_DIR=/_/src /pathmap:$env:PKG_WORK_DIR=/_/work"
$env:VCPKG_C_FLAGS = '/Brepro'
$env:VCPKG_CXX_FLAGS = '/Brepro'

# vcpkg: bootstrap the tool pinned by this checkout, then install the ports the
# bridge crates probe for. HarfBuzz is not a port here.
$vcpkgRoot = Join-Path $env:PKG_SRC_DIR 'vcpkg'
$env:VCPKG_ROOT = $vcpkgRoot
$env:VCPKG_DISABLE_METRICS = '1'
& (Join-Path $vcpkgRoot 'bootstrap-vcpkg.bat') -disableMetrics
if ($LASTEXITCODE -ne 0) { throw "vcpkg bootstrap failed with exit code $LASTEXITCODE" }

& (Join-Path $vcpkgRoot 'vcpkg.exe') install `
  --triplet x64-windows-static-md-release `
  --overlay-triplets $env:PKG_FILES_DIR `
  --x-install-root (Join-Path $vcpkgRoot 'installed') `
  fontconfig freetype graphite2 icu
if ($LASTEXITCODE -ne 0) { throw "vcpkg install failed with exit code $LASTEXITCODE" }

rustc --version
if ($LASTEXITCODE -ne 0) { throw "rustc failed with exit code $LASTEXITCODE" }
cargo --version
if ($LASTEXITCODE -ne 0) { throw "cargo failed with exit code $LASTEXITCODE" }

cargo fetch --locked --target x86_64-pc-windows-msvc
if ($LASTEXITCODE -ne 0) { throw "cargo fetch failed with exit code $LASTEXITCODE" }

cargo build --profile make --frozen
if ($LASTEXITCODE -ne 0) { throw "cargo build failed with exit code $LASTEXITCODE" }

New-Item -ItemType Directory -Force $env:PKG_OUT_DIR | Out-Null
Copy-Item -Path (Join-Path 'target/make' 'tectonic.exe') -Destination $env:PKG_OUT_DIR
