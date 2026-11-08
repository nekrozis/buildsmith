# Recipe format

A recipe is `packages/<name>/package.yml`. `pkgctl` rejects unknown keys, so a
typo fails validation instead of being silently ignored.

```yaml
name: lazygit                 # must match the directory name, [a-z][a-z0-9-]*
summary: Simple terminal UI for git commands
homepage: https://github.com/jesseduffield/lazygit
license: MIT

version:
  pkgver: 0.66.3              # upstream version, never prefixed with "v"
  pkgrel: 1                   # packaging revision, >= 1

arch: [amd64v3]               # see docs/targets.md

sources:
  - type: git
    url: https://github.com/jesseduffield/lazygit.git
    tag: v${pkgver}           # optional, but checked against the commit
    commit: e0fbfd50c36e1ef88c52297ca34750e640b4f5f4
    dir: lazygit              # plain directory name under the src root
  - type: url
    url: https://example.invalid/thing-${pkgver}.zip
    sha256: 5a37...           # required
    extract: zip              # zip | tar.gz | tar.xz | tar
    dir: thing

build:
  script: build.ps1             # relative to the recipe directory
  shell: pwsh                   # pwsh; bash is only allowed off Windows
  runner: windows-2025          # explicit image, never *-latest
  toolchain:
    go: "1.27.3"              # go | rust | msvc | zig, all optional
  env:                        # exported to the build script
    GOAMD64: v3
  overrides:                  # documented deviations from upstream defaults
    - "GOAMD64=v3, upstream goreleaser builds windows/amd64 with the default v1"
  source_date_epoch: 1704164645   # optional; otherwise the pinned commit time

stage:
  - from: ${out}              # ${out} | ${src} | ${files} | ${recipe}
    to: bin                   # path inside <name>/ in the archive

smoke:
  - [bin/lazygit.exe, --version]

reproducibility:
  level: L3
  ab: true                    # build twice and compare, see docs/reproducibility.md
  cross_env: true
  verified_on: [windows-2025]

distribution: allowed         # allowed | private-only
depends: []                   # optional, documented in the index
provides: []
conflicts: []
notes: |
  Free-form text that ends up in the manifest and the index.
```

## Placeholders

`${name}`, `${pkgver}`, `${pkgrel}` and `${arch}` are substituted in `sources`
and `stage`. In `stage`, the prefixes `${out}`, `${src}`, `${files}` and
`${recipe}` select which directory a path is relative to; anything else is
relative to `${src}`.

## Environment available to build scripts

| Variable | Meaning |
|---|---|
| `PKG_NAME`, `PKG_PKGVER`, `PKG_PKGREL`, `PKG_FULL_VERSION`, `PKG_ARCH` | resolved identity |
| `PKG_SRC_DIR` | where sources were materialised |
| `PKG_OUT_DIR` | where the build script should put files to be staged |
| `PKG_STAGE_DIR` | staging tree (managed by pkgctl) |
| `PKG_FILES_DIR` | copy of `packages/<name>/files/` |
| `PKG_RECIPE_DIR` | the recipe directory |
| `SOURCE_DATE_EPOCH` | fixed for the run |

Build scripts write into `$env:PKG_OUT_DIR`; they must not touch
`$env:PKG_STAGE_DIR`.

## Build scripts

Windows builds run in **PowerShell**, never bash: a `windows-*` runner with any
other `shell` fails `validate`, and the script suffix must match the shell
(`.ps1` for `pwsh`, `.sh` for `bash`). The reason is not taste — MSYS2 rewrites
POSIX-looking arguments such as `/arch:AVX2` into
`C:/Program Files/Git/arch:AVX2`, and its own `link.exe` plus coreutils shadow
the MSVC tools in `PATH`.

Two habits come with that choice:

- Start with `$ErrorActionPreference = 'Stop'`. PowerShell does not fail on a
  native command's non-zero exit code, so check `$LASTEXITCODE` after every
  external tool: a silently failed `cargo build` would otherwise package an
  empty archive and look like a success.
- Build paths with `Join-Path` and read the environment as `$env:NAME`.

Ubuntu jobs keep bash; they only orchestrate `pkgctl`. They need no wrapper
script either, because `pkgctl` falls back to `PACKAGE`, `PKGVER`, `PKGREL`,
`ARCH` and `WORK` from the environment when the flags are absent.

## Adding a package

1. `packages/<name>/package.yml` + `build.ps1`.
2. Resolve the real commit for the tag (`git ls-remote --tags`) and pin it.
3. Compute `sha256` for every archive source.
4. `python tools/pkgctl.py validate --package <name>`.
5. Add `.github/workflows/<name>.yml` (copy an existing one, change `package`).
6. Run the workflow without `publish`, check the manifest, then publish as a
   draft release and review it before making it public.