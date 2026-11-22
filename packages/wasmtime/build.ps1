$ErrorActionPreference = 'Stop'

Set-Location (Join-Path $env:PKG_SRC_DIR 'wasmtime')

@'

[profile.make]
inherits = "release"
opt-level = 3
debug = false
strip = "debuginfo"
debug-assertions = false
overflow-checks = false
lto = "thin"
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

# The gdbstub feature embeds a wasm32-wasip2 component that a nested cargo
# invocation builds; std for that target is not part of the toolchain install.
rustup target add wasm32-wasip2
if ($LASTEXITCODE -ne 0) { throw "rustup target add failed with exit code $LASTEXITCODE" }

# The same feature set the upstream release artifacts use.
cargo build --profile make --frozen -p wasmtime-cli `
  --features all-arch,component-model,gdbstub,run
if ($LASTEXITCODE -ne 0) { throw "cargo build failed with exit code $LASTEXITCODE" }

New-Item -ItemType Directory -Force $env:PKG_OUT_DIR | Out-Null
Copy-Item -Path (Join-Path 'target/make' 'wasmtime.exe') -Destination $env:PKG_OUT_DIR
