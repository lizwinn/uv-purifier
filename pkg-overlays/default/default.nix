# SPDX-License-Identifier: MIT
#
# The default package overlay. It adds one attribute to the package set:
# the scope `pkgs.uv-purifier`, made from the packages of pkgs/ with
# lib.makeScope. The scope holds the builder `buildUvProject` and the
# command `cli`. `pkgs.uv-purifier.overrideScope` replaces what the scope
# shares, and `pkgs.uv-purifier.buildUvProject.override` replaces what the
# builder takes. A consumer that lists this flake in `projects` holds it as
# `uv-purifier/default`, which its package sets apply by default.
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
      uv-purifier = added.uv-purifier.overrideScope (
        scopeFinal: scopePrev: {
          cli = scopePrev.cli.override { purifierSource = closure-inputs.purifier; };
        }
      );
    };
}
