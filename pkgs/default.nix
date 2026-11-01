# SPDX-License-Identifier: MIT
{ callPackage, ... }:
{
  # The `uv-purifier` command: `lock` writes uv-purifier.lock.json, `sync`
  # installs a .venv offline, and `publish` uploads what the Nix build of a
  # workspace member made. The default package overlay gives it the source
  # of the shared purifier library.
  cli = callPackage ./cli { purifierSource = null; };
}
