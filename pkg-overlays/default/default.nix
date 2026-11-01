# SPDX-License-Identifier: MIT
#
# The default package overlay. It adds the packages of pkgs/ under
# `pkgs.uv-purifier` (`.cli`), and the builder `pkgs.buildUvProject`
# (nix/lib/build-uv-project.nix) beside them, where nixpkgs keeps its own
# builders, so a package written for callPackage takes it by name. A
# consumer that lists this flake in `projects` holds it as
# `uv-purifier/default`, which its package sets apply by default.
{ closure-lib, ... }:
let
  packages = closure-lib.caisson.nixpkgs.mkPackagesOverlay ../../pkgs "uv-purifier";
in
{
  overlay =
    final: prev:
    packages final prev
    // {
      buildUvProject = final.callPackage ../../nix/lib/build-uv-project.nix { };
    };
}
