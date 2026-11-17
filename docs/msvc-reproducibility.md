# MSVC reproducibility

This page is about making a Windows build byte-identical with MSVC. It is
deliberately short: two rules decide most outcomes, and the rest is a handful
of path and metadata flags. Levels and claims are defined in
[reproducibility.md](reproducibility.md); this page is the tool-level part.

## The two rules

1. **/Brepro goes to the compiler, the librarian and the linker.** Passing it
   only to the linker leaves object-file timestamps and archive metadata
   varying between builds. Passing it only to the compiler leaves the PE
   timestamp and the debug entries varying.

2. **With /GL and /LTCG, /experimental:deterministic goes to the linker as
   well.** On the compiler the flag is equivalent to /Brepro plus warnings
   about `__TIME__`-style usage; it has no extra code-generation meaning there.
   The instruction-selection differences that survive /Brepro come from
   link-time code generation, and the link-side invocation is where the flag
   has an effect in practice. The flag is not documented by Microsoft; treat it
   as measured behaviour, not a contract.

A corollary of the first rule: **a compiler that produces objects for the MSVC
toolchain must pass /Brepro at compile time.** clang-cl takes `/Brepro`; without
it the object timestamp is the current time, and any archive or `link.exe`
invocation inherits that. Zig's msvc target is a special case: its final link
was reproducible in the measurements behind this page, but the objects it
archives are not reproducible witnesses either way.

## Recommended set (CMake, Release)

```cmake
set(CMAKE_C_FLAGS_RELEASE
  "/MD /O2 /Ob2 /DNDEBUG /arch:AVX2 /GL /Brepro /experimental:deterministic
   /pathmap:${PKG_SRC_DIR}=/_/src /pathmap:${PKG_WORK_DIR}=/_/work")
set(CMAKE_CXX_FLAGS_RELEASE "${CMAKE_C_FLAGS_RELEASE}")
set(CMAKE_STATIC_LINKER_FLAGS_RELEASE "/Brepro")
set(CMAKE_EXE_LINKER_FLAGS_RELEASE
  "/LTCG /experimental:deterministic /PDBALTPATH:%_PDB%")
set(CMAKE_SHARED_LINKER_FLAGS_RELEASE
  "/LTCG /experimental:deterministic /PDBALTPATH:%_PDB%")
```

The compiler is explicit about the pairing: without /experimental:deterministic it
answers `'/pathmap:' requires '/experimental:deterministic'; option ignored` and
leaves the absolute paths in the objects. The two flags belong together.

link.exe reads options from the `_LINK_` environment variable, which is handy
when a build script invokes link.exe without going through CMake. The recipes
put `/Brepro` and `/INCREMENTAL:NO` there; the measured PE timestamp of the
output is a content hash, so the flag does take effect through that path.

## What each flag covers

| Flag | Tool | Covers |
|---|---|---|
| /Brepro | cl | object timestamp; implies d1nodatetime (`__DATE__`, `__TIME__`, `__TIMESTAMP__`) |
| /Brepro | lib | archive metadata; measured builds still produced archives with different hashes, so it does not make the archive identical (see Limits) |
| /Brepro | link | PE timestamp (a content hash), debug entries |
| /experimental:deterministic | cl | /Brepro plus warnings; no extra codegen meaning |
| /experimental:deterministic | link | the link-time code generation path; needed with /GL /LTCG |
| /pathmap:<from>=<to> | cl | `__FILE__` and debug paths (the work-directory part of A/B); **ignored unless /experimental:deterministic is on the same command line** |
| /PDBALTPATH:%_PDB% | link | the PDB path written into the image; PDBs are not reproducible anyway |
| /INCREMENTAL:NO | link | incremental state; incompatible with reproducible links |
| /OPT:REF,ICF | link | not a determinism flag; keep it stable so the layout is comparable |

## Diagnosing a difference

- **One or two bytes in .text, instruction length unchanged** (e.g. `41 8b cb`
  vs `49 8b cb` = `mov ecx,r11d` vs `mov rcx,r11`): instruction selection. With
  /GL /LTCG check the link-side /experimental:deterministic; without LTCG the
  compiler invocation is the suspect.
- **A 49-byte pattern**: 1 byte in .text, 44 in .rdata and 4 in the PE header.
  The .rdata and header bytes look like /Brepro hashes derived from the image
  content; fixing the text byte makes them follow.
- **Paths in .rdata**: `__FILE__` strings from the build directory; add
  /pathmap. Assert and logging macros are the usual carriers.
- **Archives differ, sizes equal**: the code did not change length. The cause
  can be archive metadata or equal-length bytes inside the payload; do not
  conclude that the object code is identical either.
- **Static archives differ but import libraries match**: expected. Import
  libraries are produced by the linker, static archives by lib.exe.

## Limits

- Static archives are not a reproducibility witness yet. With `/Brepro` on
  the compiler and on `lib.exe` (verified in the build log), two builds of the
  same tree still produced archives with **identical sizes and different
  hashes**. The cause was not isolated: it can be archive member metadata or
  equal-sized differences inside the `/GL` payload. The final link output
  matched in all measured runs, but do not treat archive hashes as meaningful.
- PDBs are not deterministic. Do not ship them, and do not base a claim on
  them.
- These flags produce a same-image claim (L2). A different runner image can
  change the toolset and the Windows SDK; verify before claiming more.
- A single passing A/B is not proof. Codegen flips are rare, not impossible;
  run the comparison more than once before trusting a change.

## Measured result (love 11.5, windows-2025)

| Configuration | Builds | Outcome |
|---|---|---|
| /GL /LTCG, no link-side /experimental:deterministic | 2 | 1 leg differed |
| /GL /LTCG with the link-side flag | 12 (6 A/B runs) | all identical |

All twelve builds produced the same archive sha256 (`2e862ad1…`, 3,978,914
bytes), including the run that produced the draft release. The static archives
inside those builds were still not identical (same sizes, different hashes),
which is why the rule above is about the final link, not about archive bytes.
