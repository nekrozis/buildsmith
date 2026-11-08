$ErrorActionPreference = 'Stop'

Set-Location (Join-Path $env:PKG_SRC_DIR 'nushell')

Remove-Item -Recurse -Force '.cargo' -ErrorAction SilentlyContinue
Remove-Item -Force 'rust-toolchain.toml' -ErrorAction SilentlyContinue

@'

[profile.make]
inherits = "release"
opt-level = 3
debug = false
strip = "debuginfo"
debug-assertions = false
overflow-checks = false
lto = "fat"
panic = "unwind"
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

cargo build --profile make --frozen
if ($LASTEXITCODE -ne 0) { throw "cargo build failed with exit code $LASTEXITCODE" }

New-Item -ItemType Directory -Force $env:PKG_OUT_DIR | Out-Null
Copy-Item -Path (Join-Path 'target/make' '*.exe') -Destination $env:PKG_OUT_DIR