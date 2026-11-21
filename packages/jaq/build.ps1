$ErrorActionPreference = 'Stop'

Set-Location (Join-Path $env:PKG_SRC_DIR 'jaq')

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

# -p jaq / --bin jaq keep jaq-play (the egui playground) out of the build.
cargo build --profile make --frozen --package jaq --bin jaq
if ($LASTEXITCODE -ne 0) { throw "cargo build failed with exit code $LASTEXITCODE" }

New-Item -ItemType Directory -Force $env:PKG_OUT_DIR | Out-Null
Copy-Item -Path (Join-Path 'target/make' 'jaq.exe') -Destination $env:PKG_OUT_DIR
