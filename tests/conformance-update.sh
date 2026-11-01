#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
#
# The conformance-update check of the purifier contract: `uv-purifier
# update` on a copy of tests/fixtures/update, whose uv.lock pins six at
# 1.15.0, moves six to a newer version, and both lockfiles then pass the
# stale check: `uv lock --check`, and the problems of readLock. It needs the
# network (PyPI) and runs from the repository root:
#
#   tests/conformance-update.sh
set -euo pipefail

cli=$(nix build --no-link --print-out-paths '.#cli')
python=$(nix build --no-link --print-out-paths --inputs-from . 'nixpkgs#python3')
uv=$(nix build --no-link --print-out-paths --inputs-from . 'nixpkgs#uv')
export UV_PYTHON="$python/bin/python3" UV_PYTHON_DOWNLOADS=never

project=$(mktemp -d)/update
cp -r tests/fixtures/update "$project"
chmod -R u+w "$project"

six_version() {
  grep -A1 '^name = "six"$' "$project/uv.lock" | sed -n 's/^version = "\(.*\)"$/\1/p'
}

before=$(six_version)
"$cli/bin/uv-purifier" update --project "$project"
after=$(six_version)
echo "six: $before -> $after" >&2
if [ "$before" = "$after" ]; then
  echo "update did not move six from $before" >&2
  exit 1
fi

(cd "$project" && "$uv/bin/uv" lock --check)

problems=$(nix eval --impure --json --expr \
  "((builtins.getFlake \"git+file://$PWD\").lib.uv-purifier.readLock { src = /. + \"$project\"; }).problems")
if [ "$problems" != "[]" ]; then
  echo "the updated lockfiles have problems: $problems" >&2
  exit 1
fi
