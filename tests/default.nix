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

  # A project with a dependency of every kind uv.lock records besides an
  # index: attrs from git (built with hatch-vcs, which reads its version
  # from git), six from a GitHub archive URL, and packages from a local
  # directory, a local sdist and a local wheel.
  sources = buildUvProject { src = ./fixtures/sources; };

  # A project that depends on an editable path outside its directory,
  # which the build gets through pathSources.
  outside = buildUvProject {
    src = ./fixtures/outside/app;
    pathSources."../shared" = ./fixtures/outside/shared;
  };

  # Runs `uv-purifier sync` on a copy of a fixture, with the inputs Nix
  # built for it, then runs a script of the .venv it installed. `edit`
  # changes a member's source afterwards, and the script runs again: a
  # member installed as editable prints `edited`.
  syncs =
    name: fixture: project: script: expected: edit: edited:
    runCommand "uv-purifier-test-sync-${name}" { nativeBuildInputs = [ cli ]; } ''
      cp -r ${fixture} project
      chmod -R u+w project
      cd project
      # Python checks its cached bytecode by the modification time in
      # seconds and the size of the source, so the edit right after the
      # first run would go unseen through a cache.
      export HOME=$TMPDIR UV_CACHE_DIR=$TMPDIR/uv-cache PYTHONDONTWRITEBYTECODE=1
      uv-purifier sync --inputs ${project.interactive}
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
      touch $out
    '';

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
  simple =
    runs "simple" simple.environments.simple "simple"
      "simple attrs=25.3.0 docopt=0.6.2 markupsafe=3.0.3 &lt;nix&gt;";

  # The environment of the virtual root has app, its scripts and every
  # member app depends on.
  workspace = runs "workspace" workspace.environments.workspace "app" "hello, nix six=1.17.0";

  sources =
    runs "sources" sources.environments.sources "sources"
      "attrs=25.3.0 six=1.17.0 idna=3.10 localdir 0.3.0 localsdist 0.4.0 localwheel 0.5.0";

  outside =
    runs "outside" outside.environments.outside-app "outside-app"
      "outside-app with shared 0.2.0";

  sync-workspace =
    syncs "workspace" ./fixtures/workspace workspace "app" "hello, nix six=1.17.0"
      "sed -i 's/hello/greetings/' packages/greeting/src/greeting/__init__.py"
      "greetings, nix six=1.17.0";

  sync-sources =
    syncs "sources" ./fixtures/sources sources "sources"
      "attrs=25.3.0 six=1.17.0 idna=3.10 localdir 0.3.0 localsdist 0.4.0 localwheel 0.5.0"
      "sed -i 's/attrs=/attrs: /' src/sources/__init__.py"
      "attrs: 25.3.0 six=1.17.0 idna=3.10 localdir 0.3.0 localsdist 0.4.0 localwheel 0.5.0";

  # A member's package is what `uv build` makes: its sdist and its wheel.
  workspace-package = runCommand "uv-purifier-test-workspace-package" { } ''
    ls ${workspace.packages.app}
    test -f ${workspace.packages.app}/app-2.0.0.tar.gz
    test -f ${workspace.packages.app}/app-2.0.0-py3-none-any.whl
    touch $out
  '';

  nix-library = import ./nix-library.nix { inherit pkgs; };

  negative = import ./negative.nix { inherit pkgs; };

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
        app = builtins.attrNames workspace.packages.app.artifacts;
        greeting = builtins.attrNames workspace.packages.greeting.artifacts;
        workspaceScripts = builtins.attrNames workspace.environments.workspace.scripts;
        simpleScripts = builtins.attrNames simple.environments.simple.scripts;
      };
      expected = {
        app = [
          "app-2.0.0-py3-none-any.whl"
          "app-2.0.0.tar.gz"
        ];
        greeting = [
          "greeting-1.0.0-py3-none-any.whl"
          "greeting-1.0.0.tar.gz"
        ];
        workspaceScripts = [ "app" ];
        simpleScripts = [ "simple" ];
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
    ${lib.getExe cli} publish --help
    touch $out
  '';
}
