# SPDX-License-Identifier: MIT
#
# The flake's checks. Every one builds in the sandbox; the only network
# access is the fixed-output fetches of locked files. The checks named
# `conformance-*` are those of the purifier contract
# (github:nix-purifiers/purifier, CONTRACT.md). conformance-relock and
# conformance-rebuild need the network or a Nix of their own, so they are
# jobs of .github/workflows/check.yml.
{
  pkgs,
  cli,
  # The flake's library: `uv-purifier`, with the builder, and `purifier`.
  lib',
}:
let
  inherit (pkgs) lib runCommand;
  inherit (lib') purifier;

  # Every fixture builds the way a consumer's flake does: through the
  # library's builder, with a package set.
  build = args: lib'.uv-purifier.buildUvProject ({ inherit pkgs; } // args);

  # A single project built with hatchling. attrs installs from its wheel,
  # docopt, which has only an sdist, is built with the locked setuptools,
  # and markupsafe installs its compiled wheel for the system.
  simple = build { src = ./fixtures/simple; };

  # A virtual workspace root with two members: greeting (setuptools) and
  # app (flit-core), which depends on greeting and on six. Its test command
  # runs app's script.
  workspace = build {
    src = ./fixtures/workspace;
    testCommand = [ "app" ];
  };

  # A project with a dependency of every kind uv.lock records besides an
  # index: attrs from git (built with hatch-vcs, which reads its version
  # from git), six from a GitHub archive URL, idna from a wheel URL, and
  # packages from a local directory, a local sdist and a local wheel.
  sources = build { src = ./fixtures/sources; };

  # A project that depends on an editable path outside its directory,
  # which the build gets through pathSources.
  outside = build {
    src = ./fixtures/outside/app;
    pathSources."../shared" = ./fixtures/outside/shared;
  };

  # The simple fixture without its purifier lockfile, built from the copy
  # kept outside the source, as a packaging flake builds a project its
  # author does not change.
  external = build {
    src = lib.fileset.toSource {
      root = ./fixtures/simple;
      fileset = lib.fileset.difference ./fixtures/simple ./fixtures/simple/uv-purifier.lock.json;
    };
    lockFile = ./fixtures/simple/uv-purifier.lock.json;
  };

  # Runs `uv-purifier prefetch` on a copy of a fixture, with the inputs Nix
  # built for it, in the sandbox, which has no network, then runs a script
  # of the .venv it installed. `edit` changes a member's source afterwards,
  # and the script runs again: a member installed as editable prints
  # `edited`. pyright, the type checker behind Pylance and the pyright
  # language server, then checks `sources` against the .venv, as an editor
  # would: every import must resolve.
  offline =
    name: fixture: project: script: expected: edit: edited: sources:
    runCommand "uv-purifier-test-offline-${name}"
      {
        nativeBuildInputs = [
          cli
          pkgs.pyright
        ];
      }
      ''
        cp -r ${fixture} project
        chmod -R u+w project
        cd project
        # Python checks its cached bytecode by the modification time in
        # seconds and the size of the source, so the edit right after the
        # first run would go unseen through a cache.
        export HOME=$TMPDIR UV_CACHE_DIR=$TMPDIR/uv-cache PYTHONDONTWRITEBYTECODE=1
        uv-purifier prefetch --inputs ${project.interactive}
        check() {
          output=$(.venv/bin/${script})
          echo "$output"
          if [ "$output" != "$1" ]; then
            echo "expected: $1" >&2
            exit 1
          fi
        }
        check ${lib.escapeShellArg expected}
        ${edit}
        check ${lib.escapeShellArg edited}
        pyright --pythonpath .venv/bin/python ${lib.escapeShellArgs sources}
        touch $out
      '';

  # Runs a script and compares what it prints.
  runs =
    name: script: expected:
    runCommand "uv-purifier-test-${name}" { } ''
      output=$(${script})
      echo "$output"
      if [ "$output" != ${lib.escapeShellArg expected} ]; then
        echo "expected: "${lib.escapeShellArg expected} >&2
        exit 1
      fi
      touch $out
    '';

  negative = import ./negative.nix { inherit pkgs; };
in
{
  simple =
    runs "simple" simple.packages.simple.scripts.simple
      "simple attrs=25.3.0 docopt=0.6.2 markupsafe=3.0.3 &lt;nix&gt;";

  # The package of the virtual root has app, its scripts and every member
  # app depends on.
  workspace = runs "workspace" workspace.packages.workspace.scripts.app "hello, nix six=1.17.0";

  sources =
    runs "sources" sources.packages.sources.scripts.sources
      "attrs=25.3.0 six=1.17.0 idna=3.10 localdir 0.3.0 localsdist 0.4.0 localwheel 0.5.0";

  outside =
    runs "outside" outside.packages.outside-app.scripts.outside-app
      "outside-app with shared 0.2.0";

  # The release is what `uv build` makes for each member: its sdist and
  # its wheel.
  release = runCommand "uv-purifier-test-release" { } ''
    ls ${workspace.release}
    ${lib.concatMapStrings (file: ''
      test -f ${workspace.release.artifacts.${file}}
      test -e ${workspace.release}/${file}
    '') (builtins.attrNames workspace.release.artifacts)}
    touch $out
  '';

  # The project's test command, in its development environment.
  tests = workspace.tests;

  # Builds of the simple fixture that the conformance-rebuild job of CI
  # builds twice with `nix build --rebuild`: the sdist and wheel of its
  # member, and its environment.
  rebuild-release = simple.release.members.simple;
  rebuild-package = simple.packages.simple;

  # The download entries the build fetches, for SBOM, license and
  # vulnerability tools: a file entry per locked file, and a git entry for
  # the checkout.
  fetches =
    let
      kinds = map (
        e:
        if e ? git then
          "git"
        else if e ? url then
          "file"
        else
          "other"
      ) sources.fetches;
    in
    assert lib.elem "git" kinds && lib.elem "file" kinds && !lib.elem "other" kinds;
    runCommand "uv-purifier-test-fetches" { } "touch $out";

  conformance-offline =
    offline "sources" ./fixtures/sources sources "sources"
      "attrs=25.3.0 six=1.17.0 idna=3.10 localdir 0.3.0 localsdist 0.4.0 localwheel 0.5.0"
      "sed -i 's/attrs=/attrs: /' src/sources/__init__.py"
      "attrs: 25.3.0 six=1.17.0 idna=3.10 localdir 0.3.0 localsdist 0.4.0 localwheel 0.5.0"
      [ "src" ];

  offline-workspace =
    offline "workspace" ./fixtures/workspace workspace "app" "hello, nix six=1.17.0"
      "sed -i 's/hello/greetings/' packages/greeting/src/greeting/__init__.py"
      "greetings, nix six=1.17.0"
      [ "packages" ];

  conformance-external =
    runs "external" external.packages.simple.scripts.simple
      "simple attrs=25.3.0 docopt=0.6.2 markupsafe=3.0.3 &lt;nix&gt;";

  inherit (negative)
    conformance-stale
    conformance-tampered
    conformance-missing
    conformance-malformed
    ;

  nix-library = import ./nix-library.nix { inherit pkgs purifier; };

  flask = import ./real-world/flask {
    inherit pkgs cli;
    inherit (lib'.uv-purifier) buildUvProject;
  };

  # The unit tests of the lock tool and of split_requirements.py.
  unit =
    runCommand "uv-purifier-test-unit"
      {
        src = lib.fileset.toSource {
          root = ../.;
          fileset = lib.fileset.unions [
            ../src
            ../nix/lib
            ./unit
            ./fixtures/simple
          ];
        };
        nativeBuildInputs = [ pkgs.python3 ];
      }
      ''
        cd $src
        python3 -m unittest discover -s tests/unit -v
        touch $out
      '';

  # The outputs of a project are known by name when Nix evaluates, from
  # uv-purifier.lock.json: reading their names builds nothing.
  outputs =
    let
      found = {
        release = builtins.attrNames workspace.release.artifacts;
        workspaceScripts = builtins.attrNames workspace.packages.workspace.scripts;
        simpleScripts = builtins.attrNames simple.packages.simple.scripts;
        packages = builtins.attrNames workspace.packages;
      };
      expected = {
        release = [
          "app-2.0.0-py3-none-any.whl"
          "app-2.0.0.tar.gz"
          "greeting-1.0.0-py3-none-any.whl"
          "greeting-1.0.0.tar.gz"
        ];
        workspaceScripts = [ "app" ];
        simpleScripts = [ "simple" ];
        packages = [
          "app"
          "greeting"
          "workspace"
        ];
      };
      failures = lib.filter (name: found.${name} != expected.${name}) (lib.attrNames expected);
    in
    runCommand "uv-purifier-test-outputs" { } (
      if failures == [ ] then
        "touch $out"
      else
        ''
          echo "unexpected outputs: "${lib.escapeShellArg (builtins.toJSON (lib.getAttrs failures found))} >&2
          exit 1
        ''
    );

  cli = runCommand "uv-purifier-test-cli" { } ''
    ${lib.getExe cli} --help
    ${lib.getExe cli} lock --help
    ${lib.getExe cli} prefetch --help
    ${lib.getExe cli} publish --help
    touch $out
  '';
}
