#!/usr/bin/env bash
# Thin wrapper used by the workflows: forwards the PKG_* environment that
# GitHub Actions provides to pkgctl as explicit flags.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

python_bin="${PYTHON:-}"
if [[ -z "${python_bin}" ]]; then
  for candidate in python3 python; do
    if command -v "${candidate}" >/dev/null 2>&1; then
      python_bin="${candidate}"
      break
    fi
  done
fi
if [[ -z "${python_bin}" ]]; then
  echo "no python interpreter found" >&2
  exit 1
fi

args=(--package "${PACKAGE:?PACKAGE is required}")
if [[ -n "${PKGVER:-}" ]]; then
  args+=(--pkgver "${PKGVER}")
fi
if [[ -n "${PKGREL:-}" && "${PKGREL}" != "0" ]]; then
  args+=(--pkgrel "${PKGREL}")
fi
if [[ -n "${ARCH:-}" ]]; then
  args+=(--arch "${ARCH}")
fi

exec "${python_bin}" "${here}/pkgctl.py" "$1" "${args[@]}" "${@:2}"