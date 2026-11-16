# zig cc

Packages that use zig build their C/C++ parts with `zig cc`. The compiler is a
single checksummed archive, pinned per recipe in `tools/pkgctl.py`; a version
without an entry there is refused before anything runs. That gives a fixed
compiler, a fixed libc (for the gnu target) and a fixed linker, which is the
reason zig is used for code that has to be byte-identical between builds.

## Choosing the target

```
x86_64-windows-gnu    hermetic; zig's own CRT headers, libraries and linker
x86_64-windows-msvc   uses the runner's MSVC headers, libraries and UCRT
```

The choice is not cosmetic. `zig cc` links its `compiler_rt`, which exports the
usual libm names (`sin`, `cos`, `tan`, `exp`, `log`, `log10`, `sqrt`,
`fmod`, `sincos`, `fma`, `floor`, `ceil`, `round`, `trunc` and the float
variants) as static implementations, several of them ported from musl:

- On **windows-gnu**, `compiler_rt` comes before the `api-ms-win-crt-*` import
  libraries, and a weak definition counts as a definition in that link flavour,
  so the import libraries are never pulled. The DLL then carries the musl
  implementations: larger, and slower than the UCRT ones.
- On **windows-msvc**, the CRT arrives through `/DEFAULTLIB`, which is searched
  after the other inputs, and COFF weak externals can be overridden by a later
  strong definition. The UCRT wins and the ABI matches the rest of the package.

Use the msvc target when the package calls libm, links against MSVC-built
objects, or ships a library that MSVC code will consume. Use the gnu target for
self-contained console tools: it needs no MSVC installation and stays hermetic.

## Determinism

- Clang's code generation is deterministic for a fixed compiler and flags.
  This is why zig replaced MSVC for LuaJIT: the MSVC backend emitted two
  different but equivalent encodings for the same input across runs.
- Pass `-s` when linking DLLs and executables. Without it zig can add a PDB
  whose identifier changes with the build directory.
- The archive is checksummed and pinned, so a compiler upgrade is a deliberate
  recipe change, not a rebuild.

## Flags used here

```
ZIG_TARGET   x86_64-windows-gnu | x86_64-windows-msvc
ZIG_CPU      x86_64_v3
zig cc -target ${ZIG_TARGET} -mcpu=${ZIG_CPU} -O2 -DNDEBUG
```

`-mcpu=x86_64_v3` is the same feature level as `/arch:AVX2`; `-O2 -DNDEBUG`
matches the usual MSVC Release flags.

## Things that do not work

| Attempt | Result |
|---|---|
| `zig cc -fno-compiler-rt` | not accepted by `zig cc` (it exists in `zig build-exe`) |
| `-fno-rtlib-defaultlib` | does not remove `compiler_rt` from the link |
| reordering with `-l` | user libraries are placed after the driver's defaults |
| expecting weak linkage to save you on gnu | a weak definition satisfies the reference, so the import library is not pulled |

## Diagnosing

`zig cc -v` prints the real link line. If `compiler_rt.lib` appears before the
`api-ms-win-crt-*.lib` entries and the code calls libm, assume the static
implementations are in use. Check the imports of the produced binary: a
gnu-built DLL that calls `sin` will not import `sin`, an msvc-built one will.

## Limits

- The **msvc target is not hermetic**: it needs the MSVC toolset and Windows
  SDK on the runner, which float with the image. Reproducibility stays at the
  same-image level (L2) and must be re-verified after an image change.
- The **gnu target replaces libm**, and `compiler_rt` also exports `memset`,
  `memcpy` and friends. A package that happens not to call them looks fine.
- `zig cc` does not expose a way to drop `compiler_rt`, so the target choice is
  the only lever.
- The flag rules for an MSVC-linked build — /Brepro everywhere and the link-side
  /experimental:deterministic under /GL /LTCG — are in
  [msvc-reproducibility.md](msvc-reproducibility.md).
