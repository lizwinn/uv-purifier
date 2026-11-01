# SPDX-License-Identifier: MIT
#
# What `uv-purifier publish` builds: one workspace member's package, from a
# project directory given as an absolute path. The CLI passes the nixpkgs it
# was built with.
{
  nixpkgs,
  src,
  package,
}:
let
  pkgs = import nixpkgs { };
  # The project directory without what uv and Python leave in it.
  source = builtins.path {
    path = /. + src;
    name = "source";
    filter =
      path: type:
      !builtins.elem (baseNameOf path) [
        ".git"
        ".venv"
        "__pycache__"
        "dist"
      ];
  };
  project = pkgs.callPackage ./build-uv-project.nix { } { src = source; };
in
project.packages.${package}
  or (throw "uv-purifier: ${package} has no package; the packages are ${toString (builtins.attrNames project.packages)}")
