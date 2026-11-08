# Reproducibility

## Levels

The vocabulary used here is the one from the notes this repository grew out of:

| Level | Meaning |
|---|---|
| `L0` | builds, but output differs between runs even on the same machine |
| `L1` | stable output on one machine, not across environments |
| `L2` | byte-identical on the same runner image; expected to differ across images |
| `L3` | byte-identical across runner images and host machines |

`L3` is only claimed where it has been measured. A recipe says what it claims
and on what image it was verified:

```yaml
reproducibility:
  level: L3
  ab: true
  cross_env: true
  verified_on: [windows-2025]
```

## Current claims

| Package | Level | Evidence |
|---|---|---|
| gopls | L3 | Go toolchain, `-trimpath -buildvcs=false`, no cgo; measured identical on windows-2022 / windows-2025 / local |
| lazygit | L3 | same shape as gopls, version metadata injected from `SOURCE_DATE_EPOCH` |
| nushell | L2 | Rust + MSVC; `wshim` showed UCRT import-set drift between runner images |
| ripgrep | L2 | Rust + MSVC, PCRE2 statically linked; A/B and cross-image checks not yet run |
| fd-find | L2 | Rust + MSVC; A/B and cross-image checks not yet run |
| aseprite | L2 | MSVC + CMake + a prebuilt Skia binary |

`cross_env: true` is only written after an actual cross-image comparison. Until
then the honest value is `false`, and the manifest says so.

## A/B procedure

`reproducibility.ab: true` makes the workflow build the package **twice**, in
two separate matrix legs, with:

- separate work directories (`work/a`, `work/b`),
- separate staging trees and separate output archives (`dist/a`, `dist/b`),
- no shared compiler cache (the recipes disable ccache; Go/Rust caches are off
  in CI for the same reason).

`pkgctl assemble` then compares the staged file lists and hashes, and the zip
digest. Only if both match does it write:

```json
"reproducibility": {
  "ab": "same-image",
  "ab_verified": true,
  "ab_sha256": ["...", "..."]
}
```

Running the build twice in one directory, or reusing a cache, does not count and
is not what this does.

## What makes the output stable

- `SOURCE_DATE_EPOCH` — from `build.source_date_epoch` when set, otherwise the
  commit time of the first git source; exported to every build script.
- Deterministic zip — sorted entries, fixed timestamps clamped to
  `SOURCE_DATE_EPOCH` (never below the 1980 ZIP floor), fixed permission bits,
  fixed compression level, no extra fields.
- `-trimpath -buildvcs=false` (Go), `/Brepro` and `/INCREMENTAL:NO` (MSVC),
  pinned toolchain versions, pinned runner images.
- No timestamps written by us; version strings that embed a date are derived
  from `SOURCE_DATE_EPOCH`, not from `date`.

## Manifest fields

Every archive ships next to a `<archive>.manifest.json` containing:

`name`, `summary`, `homepage`, `license`, `distribution`, `notes`, `depends`,
`provides`, `conflicts`, `version{pkgver,pkgrel,full}`, `arch`,
`archive{file,format,root,size,sha256}`, `files[{path,size,sha256,mode}]`,
`sources[{type,url,tag,commit,sha256}]`,
`build{script,shell,runner,recipe_sha256,script_sha256,env,overrides}`,
`toolchain{go,rust,msvc,zig,runner,runner_image}`,
`reproducibility{level,ab,ab_verified,ab_sha256,cross_env,verified_on}`,
`source_date_epoch`, and `provenance` when an attestation was attached.

`recipe_sha256` and `script_sha256` matter: they let you tell "same recipe" from
"same version, different build" without trusting the git tag.

`toolchain.runner_image` is the `ImageVersion` environment variable of the
runner, i.e. the actual image build the artifact came from. For MSVC packages
that value, not the `windows-2025` label, is the meaningful pin.

## Toolchain policy

**Compilers are pinned exactly** (`go: "1.27.3"`, `rust: "1.99.1"`). Floating
`stable` was rejected: it silently changes the bytes of an unchanged `pkgver`,
which destroys both A/B comparison and any claim about a released archive.

**Upstream toolchain files do not override that pin.** When a project ships its
own `rust-toolchain.toml` or `.cargo/config.toml`, the build drops the file and
uses the repository's compiler instead. The artifact is ours, not upstream's, so
inheriting their compiler choice buys nothing and only fragments the toolchain
across packages: `nushell` pins an older rustc, we build it with the repository's
pinned stable rustc, the way a distribution does.

**zig is downloaded by us, not by the runner.** `toolchain.zig: "0.17.1"` is
resolved through a table inside `pkgctl` that carries the archive URL and its
sha256; a version absent from that table is refused before anything runs, so a
recipe cannot silently pick up an unpinned compiler. The archive is verified
byte for byte, unpacked under the build's own directory and put on `PATH` for
the build step. That makes the zig compiler *stronger* than an MSVC pin:
`windows-2025` refreshes can change the MSVC toolset under an unchanged recipe,
while a zig package gets the same compiler on any x64 machine, Windows or Linux.

**A toolchain update does not rebuild anything.** Bumping a compiler is a
`pkgrel` bump, made deliberately:

- the new compiler produces different bytes, so it must be a new artifact, not a
  replacement of an existing one;
- users need a version they can point at when a regression shows up;
- automatic rebuilds would rewrite the repository every few weeks for no
  user-visible benefit.

The one exception worth planning for is a compiler *security or miscompilation*
advisory: that justifies a rebuild of everything affected, still as `pkgrel + 1`,
still reviewed as a normal batch of releases.

## Known weak points

- **MSVC is not exactly pinnable.** `toolchain.msvc: "17"` plus a pinned runner
  image is the closest thing available without shipping a VS installer manifest.
  The manifest records the image version, and a cross-image rebuild is expected
  to differ (`L2`, not a bug).
- **MSVC toolset updates inside an image.** `windows-2025` images are refreshed
  monthly. If a build must be bit-identical to a previous one, record
  `toolchain.runner_image` and verify against a pinned image label instead.
- **Skia is a prebuilt binary** from `aseprite/skia`. It is pinned by sha256, so
  it cannot change under us, but its own reproducibility is out of our hands.
- **zig's target libc is shipped inside the compiler.** `x86_64-windows-gnu`
  links against zig's own copy of mingw-w64 and the UCRT headers, so the result
  does not depend on any sysroot installed on the runner. The zig archive itself
  is pinned by sha256, so a rebuild in a different directory or on a different
  image has no moving part left except the host CPU.
- **Signing.** Authenticode and hashing are mutually exclusive: signing rewrites
  the file. If packages are ever code-signed, sign `SHA256SUMS` or publish a
  separate signed copy with its own digest. Nothing in this repository signs
  binaries today.