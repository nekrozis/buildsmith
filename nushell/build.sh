set -euo pipefail

git clone --branch ${pkgver} https://github.com/nushell/nushell.git

pushd nushell


cat <<EOF >> ./Cargo.toml
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

rm -rf ./.cargo/ && ls -al

cargo fetch --locked --target x86_64-pc-windows-msvc

cargo build --profile make --frozen

mkdir ../release
cp target/make/*.exe ../release/
