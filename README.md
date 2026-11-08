# buildsmith

Source-built Windows packages, produced on GitHub-hosted runners and published
as verifiable release archives.

This repository is a *package repository*, not a pile of CI scripts: every
package is described by a recipe under `packages/`, one tool (`tools/pkgctl.py`)
does the fetching, building, deterministic packaging, A/B comparison and index
generation, and the workflows only orchestrate it.

## Layout

```
packages/<name>/package.yml   recipe: sources, pins, toolchain, stage map
packages/<name>/build.sh      build script (bash)
packages/<name>/build.ps1     build script (pwsh)
packages/<name>/files/        static files shipped inside the archive
tools/pkgctl.py               the only entry point for build/package/publish
tools/test_pkgctl.py          offline tests for the tool
index/index.json              generated package index (committed)
docs/                         recipe format, arch targets, reproducibility, publishing
```

## Artifacts

One archive per package, version and architecture:

```
<name>-<pkgver>-<pkgrel>-<arch>.zip        e.g. gopls-0.24.0-1-amd64v3.zip
<name>-<pkgver>-<pkgrel>-<arch>.manifest.json
SHA256SUMS
```

Inside the archive every file lives under `<name>/`, executables under
`<name>/bin/`. Timestamps, permissions and entry order are normalised, so
packaging the same tree twice produces the same bytes.

## Running it locally

```bash
python -m pip install -r tools/requirements.txt

python tools/pkgctl.py validate --all              # recipe schema checks
python tools/pkgctl.py plan --package gopls        # resolved, rendered plan
python tools/pkgctl.py build --package gopls --id a --work work
python tools/pkgctl.py smoke --package gopls --id a --work work
python tools/pkgctl.py package --package gopls --id a --work work --out dist/a
python tools/pkgctl.py verify --manifest dist/a/gopls-0.24.0-1-amd64v3.manifest.json
```

`python tools/test_pkgctl.py` runs the tool tests; they are hermetic (temporary
repositories, local git fixtures, no network).

## CI

- `package.yml` — reusable: plan, build (one job per build id), assemble and
  attest. Called by the per-package workflows.
- `publish.yml` — reusable: re-verifies the archive and creates a **draft**
  GitHub release. Only invoked when a workflow run asks for `publish`.
- `<package>.yml` — manual trigger with optional `pkgver` / `pkgrel` /
  `publish` inputs.
- `index.yml` — weekly (or manual) regeneration of `index/index.json` from the
  published release assets.
- `ci.yml` — recipe validation, workflow lint, tool tests.

Workflows run with `contents: read`; write access and the `release`
environment only exist on the publish job.

## Policy

- Versions come from the recipe; `workflow_dispatch` inputs override them for a
  single run. A rebuilt archive is a new `pkgrel`, never a replaced asset.
- Sources are pinned to full commit SHAs (and to verified sha256 digests for
  archives). A moved tag fails the build instead of silently changing inputs.
- Toolchains are pinned per recipe. Updating a compiler is a deliberate `pkgrel`
  bump, not an automatic rebuild.
- `distribution: private-only` packages are excluded from the index and cannot
  be published (`aseprite` is one, see `docs/publishing.md`).

## Status

Working: recipes, deterministic packaging, manifests, A/B comparison,
attestations, draft releases, index generation.

Not implemented yet: signed index (minisign), mirror array in the index,
CNB mirror job, automatic upstream-release triggers, SBOM.