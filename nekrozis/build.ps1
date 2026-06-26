$ErrorActionPreference = 'Stop'

New-Item -ItemType Directory -Force pkgdir
Set-Location pkgdir

git.exe clone https://github.com/nekrozis/shim.git
git.exe clone https://github.com/nekrozis/msys2_shell.git

Push-Location shim

$env:RUSTFLAGS = "-C target-cpu=x86-64-v3"
$env:_LINK_ = "/INCREMENTAL:NO /OPT:REF,ICF /Brepro"

Set-Location shim 
cargo.exe build --workspace --release

$env:RUSTFLAGS = $null
$env:_LINK_ = $null

Pop-Location

Push-Location msys2_shell

$env:_LINK_ = "/INCREMENTAL:NO /OPT:REF,ICF /Brepro"

cargo build --release

$env:_LINK_ = $null

Pop-Location

New-Item -ItemType Directory -Force release

Copy-Item -Path shim/shim/target/release/fwd-c.exe -Destination release/shim_console.exe
Copy-Item -Path shim/shim/target/release/fwd-w.exe -Destination release/shim_gui.exe
Copy-Item -Path msys2_shell/target/release/msys2_shell_rs.exe -Destination release/msys2_shell.exe
Copy-Item -Path ../nekrozis/msys2_shell.json -Destination release/

