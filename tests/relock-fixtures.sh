#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
#
# Relocks the test fixtures: `uv lock`, then `uv-purifier lock`, in every
# fixture directory that holds a pyproject.toml with a uv.lock beside it,
# each with the uv of the flake's package set, which is the uv the checks
# build with. It needs the network (PyPI and GitHub) and runs from the
# repository root:
#
#   tests/relock-fixtures.sh
set -euo pipefail

cli=$(nix build --no-link --print-out-paths '.#cli')
uv=$(nix build --no-link --print-out-paths --inputs-from . 'nixpkgs#uv')
python=$(nix build --no-link --print-out-paths --inputs-from . 'nixpkgs#python3')

export UV_PYTHON="$python/bin/python3" UV_PYTHON_DOWNLOADS=never

for lockfile in tests/fixtures/*/uv.lock tests/fixtures/*/*/uv.lock; do
  [ -e "$lockfile" ] || continue
  fixture=$(dirname "$lockfile")
  echo "relocking $fixture" >&2
  (cd "$fixture" && "$uv/bin/uv" lock && "$cli/bin/uv-purifier" lock)
done
