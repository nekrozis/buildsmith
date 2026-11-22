$ErrorActionPreference = 'Stop'

Set-Location (Join-Path $env:PKG_SRC_DIR 'wasmtime')

# Cranelift generates Rust sources at build time and the panic locations of
# that generated code embed the absolute output path. The A/B legs build in
# different work directories, so remap the prefixes the same way the other
# Rust recipes do.
$env:RUSTFLAGS = "$env:RUSTFLAGS " +
  "--remap-path-prefix=$env:PKG_SRC_DIR=/_/src " +
  "--remap-path-prefix=$env:PKG_WORK_DIR=/_/work"

@'

[profile.make]
inherits = "release"
opt-level = 3
debug = false
strip = "debuginfo"
debug-assertions = false
overflow-checks = false
lto = "fat"
panic = "abort"
incremental = false
codegen-units = 1
rpath = false
'@ | Add-Content -Path 'Cargo.toml' -Encoding utf8NoBOM

rustc --version
if ($LASTEXITCODE -ne 0) { throw "rustc failed with exit code $LASTEXITCODE" }

cargo --version
if ($LASTEXITCODE -ne 0) { throw "cargo failed with exit code $LASTEXITCODE" }

cargo fetch --locked --target x86_64-pc-windows-msvc
if ($LASTEXITCODE -ne 0) { throw "cargo fetch failed with exit code $LASTEXITCODE" }

cargo build --profile make --frozen -p wasmtime-cli `
  --features all-arch,component-model,run
if ($LASTEXITCODE -ne 0) { throw "cargo build failed with exit code $LASTEXITCODE" }

New-Item -ItemType Directory -Force $env:PKG_OUT_DIR | Out-Null
Copy-Item -Path (Join-Path 'target/make' 'wasmtime.exe') -Destination $env:PKG_OUT_DIR
