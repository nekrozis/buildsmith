# index

`index.json` is generated — do not edit it by hand.

```bash
python tools/pkgctl.py index \
  --manifests <directory with *.zip + *.manifest.json> \
  --out index/index.json \
  --repo <owner>/<name> \
  --verify
```

`--verify` re-hashes every archive against its manifest before it is indexed.
The `index` workflow runs this against all published release assets, so the
committed file always describes what is actually downloadable.

Packages with `distribution: private-only` are skipped, and can only be included
with the explicit `--include-private` flag (used for local inspection, never in
CI).