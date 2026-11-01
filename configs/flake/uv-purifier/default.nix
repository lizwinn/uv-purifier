# SPDX-License-Identifier: MIT
{ ... }:
{
  config,
  inputs,
  lib,
  ...
}:
{

  imports = [ inputs.flake-parts.flakeModules.partitions ];

  debug = false;
  caisson = {
    libOverlays.exported = libOverlays: {
      inherit (libOverlays) default;
    };

    # The scope `uv-purifier` is the `default` entry of this flake's package
    # overlay registry (pkg-overlays/): the package set applies it by
    # default, and the flake exports it as `pkgOverlays` and as the plain
    # `overlays.default`. The scope holds the builder, which is a function,
    # so the `packages` output below takes the derivations of the scope.
    nixpkgs = {
      packages.export.enabled = false;
    };
  };

  # `nix run github:nix-purifiers/uv-purifier -- lock` writes
  # uv-purifier.lock.json for the uv project in the current directory.
  # `nix develop github:nix-purifiers/uv-purifier` gives the uv that the
  # Nix builds run, with the CLI.
  perSystem =
    { config, pkgs, ... }:
    {
      packages = lib.filterAttrs (_: lib.isDerivation) pkgs.uv-purifier // {
        default = config.packages.cli;
      };
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
