# SPDX-License-Identifier: MIT
#
# The `uv-purifier` library namespace of the purifier contract:
# - `buildUvProject { pkgs, src, fetchers ? { }, ... }`
#   (nix/lib/build-uv-project.nix), the builder;
# - `readLock { src, lockFile ? ... }` (nix/lib/read-lock.nix), the
#   lockfiles read into the lock in memory.
# Both build on the `purifier` library, which this flake lists in its
# projects.
{ ... }:
{

  overlay = final: prev: {
    uv-purifier = (prev.uv-purifier or { }) // {
      readLock = import ../../nix/lib/read-lock.nix { lib = final; };
      buildUvProject = import ../../nix/lib/build-uv-project.nix {
        inherit (final) purifier;
        lib = final;
      };
    };
  };

}
