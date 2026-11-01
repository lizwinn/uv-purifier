# SPDX-License-Identifier: MIT
{ callPackage, ... }:
{
  # The `uv-purifier` command: `lock` writes uv-purifier.lock.json, and
  # `publish` uploads what the Nix build of a workspace member made.
  cli = callPackage ./cli { };
}
