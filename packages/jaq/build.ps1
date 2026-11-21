# Placeholder recipe: this package exists so the CI workflow can be exercised
# from other branches. It stages a marker instead of building jaq.
New-Item -ItemType Directory -Force $env:PKG_OUT_DIR | Out-Null
Set-Content -Path (Join-Path $env:PKG_OUT_DIR 'placeholder.txt') `
  -Value 'jaq: placeholder build' -Encoding ascii
