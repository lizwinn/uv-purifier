# SPDX-License-Identifier: MIT
#
# The `uv-purifier` library namespace, with the builder of the purifier
# contract: `lib.uv-purifier.buildUvProject { pkgs, src, fetchers ? { },
# ... }` (nix/lib/build-uv-project.nix). It builds on the `purifier`
# library, which this flake lists in its projects.
{ ... }:
{

  overlay = final: prev: {
    uv-purifier = (prev.uv-purifier or { }) // {
      buildUvProject = import ../../nix/lib/build-uv-project.nix { inherit (final) purifier; };
    };
  };

}
