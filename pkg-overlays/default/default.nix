# SPDX-License-Identifier: MIT
#
# The default package overlay. It adds the packages of pkgs/ under
# `pkgs.uv-purifier` (`.cli`). A consumer that lists this flake in
# `projects` holds it as `uv-purifier/default`, which its package sets
# apply by default. The builder is in the library, as
# `lib.uv-purifier.buildUvProject`.
#
# The command takes the source of the shared purifier library, for the
# builds it runs outside a flake.
{ closure-lib, closure-inputs, ... }:
let
  packages = closure-lib.caisson.nixpkgs.mkPackagesOverlay ../../pkgs "uv-purifier";
in
{
  overlay =
    final: prev:
    let
      added = packages final prev;
    in
    added
    // {
      uv-purifier = added.uv-purifier // {
        cli = added.uv-purifier.cli.override { purifierSource = closure-inputs.purifier; };
      };
    };
}
