# SPDX-License-Identifier: MIT
#
# What the `uv-purifier` command builds for a project directory given as an
# absolute path, with the nixpkgs the command was built with:
# - with `package`, that workspace member's package, which `publish`
#   uploads;
# - without it, the inputs of a development environment, which `sync`
#   installs into the project's .venv.
#
# A local package that uv.lock names by a path outside the project is read
# from that path.
{
  nixpkgs,
  # The source of the shared purifier library.
  purifier,
  src,
  package ? null,
}:
let
  pkgs = import nixpkgs { };
  inherit (pkgs) lib;

  # A directory without what uv, Python and git leave in it.
  source =
    path:
    builtins.path {
      inherit path;
      name = "source";
      filter =
        p: type:
        !builtins.elem (baseNameOf p) [
          ".git"
          ".venv"
          "__pycache__"
          "dist"
        ];
    };

  root = /. + src;
  uvLock = builtins.fromTOML (builtins.readFile (root + "/uv.lock"));
  localKinds = [
    "path"
    "directory"
    "editable"
  ];
  localPaths = lib.concatMap (
    p:
    let
      source = p.source or { };
    in
    map (kind: source.${kind}) (builtins.filter (kind: source ? ${kind}) localKinds)
  ) (uvLock.package or [ ]);
  outside = builtins.filter (
    path: path == ".." || lib.hasPrefix "../" path || lib.hasPrefix "/" path
  ) localPaths;
  # Nix paths are normalized, so ".." in the string leaves the project.
  absolute = path: if lib.hasPrefix "/" path then /. + path else /. + "${src}/${path}";
  pathSources = lib.genAttrs outside (
    path:
    let
      target = absolute path;
    in
    if lib.pathIsDirectory target then source target else target
  );

  project =
    pkgs.callPackage ./build-uv-project.nix
      { purifier = import "${purifier}/nix/lib" { inherit lib; }; }
      {
        src = source root;
        inherit pathSources;
      };
in
if package == null then
  project.interactive
else
  project.packages.${package}
    or (throw "uv-purifier: ${package} has no package; the packages are ${toString (builtins.attrNames project.packages)}")
