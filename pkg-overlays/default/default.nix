# SPDX-License-Identifier: MIT
#
# The default package overlay. It adds the packages of pkgs/ under
# `pkgs.uv-purifier` (`.cli`), and the builder `pkgs.buildUvProject`
# (nix/lib/build-uv-project.nix), where nixpkgs keeps its own builders, so
# a package written for callPackage takes it by name. A consumer that lists
# this flake in `projects` holds it as `uv-purifier/default`, which its
# package sets apply by default.
#
# The command and the builder both use the shared purifier library that
# this flake is pinned to: the command takes its source, for the builds it
# runs outside a flake, and the builder takes the library itself.
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
      buildUvProject = final.callPackage ../../nix/lib/build-uv-project.nix {
        inherit (closure-lib) purifier;
      };
    };
}
