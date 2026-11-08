#!/usr/bin/env bash
set -euo pipefail

cd "$PKG_SRC_DIR/nushell"

rm -rf .cargo
rm -f rust-toolchain.toml

cat >> Cargo.toml <<'EOF'

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
EOF

rustc --version
cargo --version

cargo fetch --locked --target x86_64-pc-windows-msvc
cargo build --profile make --frozen

mkdir -p "$PKG_OUT_DIR"
cp target/make/*.exe "$PKG_OUT_DIR/"