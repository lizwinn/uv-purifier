# SPDX-License-Identifier: MIT
{ closure-lib, ... }:
{
  config,
  inputs,
  lib,
  ...
}:
{

  imports = [
    inputs.flake-parts.flakeModules.partitions
    closure-lib.caisson.modules.flake."purifier/purifier-packages"
  ];

  # The scope `uv-purifier` is the `default` entry of this flake's package
  # overlay registry (pkg-overlays/): the package set applies it by
  # default, and the flake exports it as `pkgOverlays` and as the plain
  # `overlays.default`. The flake publishes the derivations of the scope as
  # its `packages`.
  purifier.scope = "uv-purifier";

  debug = false;
  caisson = {
    libOverlays.exported = libOverlays: {
      inherit (libOverlays) default;
    };
  };

  # `nix run github:nix-purifiers/uv-purifier -- lock` writes
  # uv-purifier.lock.json for the uv project in the current directory.
  # `nix develop github:nix-purifiers/uv-purifier` gives the uv that the
  # Nix builds run, with the CLI.
  perSystem =
    { config, pkgs, ... }:
    {
      packages.default = config.packages.cli;
      devShells.default = pkgs.mkShell {
        packages = [
          pkgs.uv
          config.packages.cli
        ];
      };
    };

  partitionedAttrs.checks = "checks";
  partitionedAttrs.formatter = "formatter";

  partitions.formatter = {
    extraInputs = (lib.caisson.pins.flake-compat ../../../tests/dependencies).sources;
    module =
      { inputs, ... }:
      {
        imports = [ inputs.treefmt-nix.flakeModule ];
        perSystem.treefmt.programs.nixfmt.enable = true;
      };
  };

  partitions.checks = {
    extraInputs = (lib.caisson.pins.flake-compat ../../../tests/dependencies).sources;
    module =
      { inputs, self, ... }:
      {
        imports = [ inputs.treefmt-nix.flakeModule ];
        perSystem =
          { pkgs, system, ... }:
          {
            checks = import ../../../tests {
              inherit pkgs;
              inherit (self.packages.${system}) cli;
              lib' = self.lib;
              overlay = self.overlays.default;
            };
            treefmt.programs.nixfmt.enable = true;
          };
      };
  };

}
