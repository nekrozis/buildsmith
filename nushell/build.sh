set -euo pipefail

mkdir pkgdir && pushd pkgdir

git clone --branch ${pkgver} https://github.com/nushell/nushell.git

pushd nushell

rm -rf rust-toolchain.toml 

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

export RUSTUP_TOOLCHAIN=stable

SOURCE_DATE_EPOCH=$(
  gh release view ${pkgver} \
    --repo nushell/nushell \
    --json publishedAt --jq '.publishedAt' \
  | xargs -I{} date -d "{}" +%s
)

echo SOURCE_DATE_EPOCH=$SOURCE_DATE_EPOCH
export SOURCE_DATE_EPOCH=$SOURCE_DATE_EPOCH

cargo fetch --locked --target x86_64-pc-windows-msvc

cargo build --profile make --frozen

mkdir ../release
cp target/make/*.exe ../release/
