# Architecture targets

Every package in this repository is built for **one** target: `amd64v3`
(x86-64-v3, AVX2 class). There is no baseline variant, matching what Arch,
CachyOS and Gentoo do by default: ship the optimised build, and let the package
name carry the requirement.

```
amd64    baseline x86-64 (SSE2)
amd64v3  AVX2 + FMA + BMI1 + BMI2 + LZCNT + MOVBE
arm64    reserved slot, nothing built today
```

The name is a slot in the artifact name (`<name>-<ver>-<rel>-amd64v3.zip`). If a
baseline is ever needed it becomes `amd64` and neither the index schema nor the
client code changes.

## What each toolchain flag actually means

| Toolchain | Flag | Effective level |
|---|---|---|
| Go | `GOAMD64=v3` | exactly x86-64-v3, per the Go toolchain docs |
| Rust | `-C target-cpu=x86-64-v3` | exactly x86-64-v3, per rustc's target cub |
| MSVC | `/arch:AVX2` | the v3 feature level, see below |
| MSVC | `/favor:AMD64` etc. | none of these raise the requirement |
| zig cc | `-mcpu=x86_64_v3` | exactly x86-64-v3: clang's `x86-64-v3` CPU model for the target |
| zig cc | `-target x86_64-windows-gnu` | not a level: the mingw-w64 ABI on the UCRT, see below |

`-mcpu=x86_64_v3` also leaves the *target* alone: `x86_64-windows-gnu` is the
mingw-w64 ABI on the UCRT, i.e. the same runtime family the MSVC packages
require, not the legacy msvcrt mingw. A `less.exe` built this way imports only
`api-ms-win-crt-*` plus `USER32`/`SHELL32`, with no libgcc or libwinpthread-1
DLL, so it needs no mingw installation on the machine that runs it.

### MSVC `/arch:AVX2` is a level, not a single instruction set

The current Microsoft documentation for `/arch (x64)` states:

> AVX2 extends most integer operations to 256-bit vectors and enables use of
> Fused Multiply-Add (FMA) instructions.

and, about the non-vector side:

> Each /arch option may also enable the use of other nonvector instructions that
> are associated with that option. An example is the use of certain BMI
> instructions when /arch:AVX2 is specified.

So `/arch:AVX2` selects the AVX2 *level*: 256-bit integer SIMD plus FMA, and it
may also emit BMI. That is the same feature set x86-64-v3 guarantees, which is
why `amd64v3` is the correct label for the MSVC packages too.

Two consequences worth writing down:

1. **The label describes the minimum requirement, not the instruction
   inventory.** A build that happens to emit no `lzcnt` is still correctly
   labelled `amd64v3`; it runs everywhere a real v3 build runs. Labelling by
   "which instructions did I see in objdump" would be both unstable and wrong.
2. **`/arch:AVX2` is not `/arch:AVX` plus a bit.** `/arch:AVX` stops before FMA
   and before 256-bit integer operations, so a `/arch:AVX` build is *not* v3.

Earlier internal notes claimed MSVC had "no equivalent switch" for FMA/BMI and
that the MSVC packages were therefore "v3 minus FMA/BMI". That was wrong; this
document supersedes it. The only honest caveat left is that MSVC never promises
to *use* every v3 instruction, only that it will not exceed the level.

## Why not v4 / AVX-512

- v4 halves the set of machines that can run the binaries while helping very few
  workloads in this repository (shells, TUIs, a language server, a sprite
  editor).
- MSVC's `/arch:AVX512` support has been historically uneven and `lazygit` /
  `gopls` gain nothing measurable from wider vectors.
- Costs are asymmetric: raising the level later is one flag plus one `pkgrel`
  bump; discovering that half your users get `SIGILL` is not recoverable for
  those bytes.

## Runtime check for users

The `amd64v3` requirement is encoded in the artifact name and in
`arch` in the index, so a client can refuse to install it on a v1/v2 machine.
Nothing in the archive inspects the CPU at runtime; that is intentional, since
`__builtin_cpu_supports`-style fallbacks would defeat the point of a single
optimised build.