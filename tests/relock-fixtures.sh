#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
#
# Relocks the test fixtures: `uv lock`, then `uv-purifier lock`, each with
# the uv of the flake's package set, which is the uv the checks build with.
# It needs the network (PyPI) and runs from the repository root:
#
#   tests/relock-fixtures.sh
set -euo pipefail

cli=$(nix build --no-link --print-out-paths '.#cli')
uv=$(nix build --no-link --print-out-paths --inputs-from . 'nixpkgs#uv')
python=$(nix build --no-link --print-out-paths --inputs-from . 'nixpkgs#python3')

export UV_PYTHON="$python/bin/python3" UV_PYTHON_DOWNLOADS=never

for fixture in tests/fixtures/*/; do
  echo "relocking $fixture" >&2
  (cd "$fixture" && "$uv/bin/uv" lock && "$cli/bin/uv-purifier" lock)
done
