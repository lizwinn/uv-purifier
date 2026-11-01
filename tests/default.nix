# SPDX-License-Identifier: MIT
#
# The flake's checks. Every one builds in the sandbox; the only network
# access is the fixed-output fetches of locked files.
{
  pkgs,
  # The flake's default package overlay, which adds buildUvProject.
  overlay,
  cli,
}:
let
  inherit (pkgs) lib;

  # Every fixture builds the way a consumer's package does: through
  # buildUvProject of a package set the overlay applies to.
  withOverlay = pkgs.extend overlay;
  inherit (withOverlay) buildUvProject runCommand;

  # A single project built with hatchling. attrs installs from its wheel,
  # and docopt, which has only an sdist, is built with the locked
  # setuptools.
  simple = buildUvProject { src = ./fixtures/simple; };

  # A virtual workspace root with two members: greeting (setuptools) and
  # app (flit-core), which depends on greeting and on six.
  workspace = buildUvProject { src = ./fixtures/workspace; };

  # Runs a script of an environment and compares what it prints.
  runs =
    name: environment: script: expected:
    runCommand "uv-purifier-test-${name}" { } ''
      output=$(${environment}/bin/${script})
      echo "$output"
      if [ "$output" != ${lib.escapeShellArg expected} ]; then
        echo "expected: "${lib.escapeShellArg expected} >&2
        exit 1
      fi
      touch $out
    '';
in
{
  simple = runs "simple" simple.environments.simple "simple" "simple attrs=25.3.0 docopt=0.6.2";

  # The environment of the virtual root has app, its scripts and every
  # member app depends on.
  workspace = runs "workspace" workspace.environments.workspace "app" "hello, nix six=1.17.0";

  # A member's package is what `uv build` makes: its sdist and its wheel.
  workspace-package = runCommand "uv-purifier-test-workspace-package" { } ''
    ls ${workspace.packages.app}
    test -f ${workspace.packages.app}/app-2.0.0.tar.gz
    test -f ${workspace.packages.app}/app-2.0.0-py3-none-any.whl
    touch $out
  '';

  nix-library = import ./nix-library.nix { inherit pkgs; };

  cli = runCommand "uv-purifier-test-cli" { } ''
    ${lib.getExe cli} --help
    ${lib.getExe cli} lock --help
    ${lib.getExe cli} publish --help
    touch $out
  '';
}
