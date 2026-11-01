# uv-purifier

uv-purifier lets Nix build a [uv](https://docs.astral.sh/uv/) project in its
sandbox, offline, from the project's lockfiles. You do not commit generated
Nix files to the project.

uv.lock already pins every dependency of the project with its URL and hash,
and the Nix library reads it directly. What uv.lock leaves out are the build
requirements: the build backend of each workspace member, and the packages
needed to build a dependency from its source. `uv-purifier lock` resolves
those with uv and writes them to `uv-purifier.lock.json` beside uv.lock.

## Lock

From the directory that holds uv.lock:

```zsh
nix run github:nix-purifiers/uv-purifier -- lock
```

Commit `uv-purifier.lock.json`. Run it again whenever uv.lock changes, or
the `[build-system]` table of a source tree in the project. The Nix build,
`sync` and `publish` refuse a `uv-purifier.lock.json` that no longer
matches them, or that was edited by hand, and say which command to run.

A relock resolves the build requirements as of the time the lockfile
records, so it keeps their versions and reproduces the lockfile byte for
byte when nothing else changed. `uv-purifier lock --upgrade` resolves them
anew.

For every package the build may have to build (a workspace member, a
dependency from git, a URL or a local path, and a dependency from an index
that has no wheel for every platform), the lock run reads the static build
requirements and asks the build backend for the ones it adds through the
PEP 517 hooks, such as hatchling's `editables`. It resolves each set for
every platform with `uv lock`, as uv.lock is resolved.

The command checks uv.lock with the uv of the flake's package set, which is
the uv the Nix build runs. `nix develop github:nix-purifiers/uv-purifier`
gives a shell with that uv and the `uv-purifier` command.

## Build

The flake's `overlays.default` adds `buildUvProject` to a package set:

```nix
{
  inputs.uv-purifier.url = "github:nix-purifiers/uv-purifier";
  inputs.nixpkgs.follows = "uv-purifier/nixpkgs";

  outputs = { nixpkgs, uv-purifier, ... }:
    let
      system = "x86_64-linux";
      pkgs = import nixpkgs {
        inherit system;
        overlays = [ uv-purifier.overlays.default ];
      };
      project = pkgs.buildUvProject { src = ./.; };
    in
    {
      # A virtual environment with the member `app`, its dependencies and its
      # scripts in bin/.
      packages.${system}.default = project.environments.app;
      # The sdist and wheel of `app`, as `uv build` makes them.
      packages.${system}.app-dist = project.packages.app;
    };
}
```

For each workspace member, `buildUvProject` gives:

- `environments.<member>`, a virtual environment with the member and its
  runtime dependencies installed, and the member's scripts in `bin/`.
  A virtual workspace root has an environment too.
- `packages.<member>`, the member's sdist and wheel, which is what
  `uv publish` uploads. A virtual root has no package.

Nix knows these outputs by name when it evaluates, from the lockfiles,
without building anything and without generated Nix files:

- `packages.<member>.artifacts."<file name>"` is each file of the package,
  such as `packages.app.artifacts."app-2.0.0-py3-none-any.whl"`.
- `environments.<member>.scripts.<script>` is each script the environment
  installs for the member and the members it depends on, such as
  `environments.app.scripts.app`.

`uv-purifier lock` records them by building each member once with
`uv build`, so scripts that a setup.py defines are included. A compiled
member's wheel name gets the CPython and Linux platform tags of the system
it is built for. Each build checks that it made what the lockfile records.

`buildUvProject` takes these arguments besides `src`:

- `python` (default `python3`), which must satisfy the project's
  `requires-python`.
- `pathSources`, the local packages that uv.lock names by a path outside
  `src`, such as `pathSources."../shared" = ../shared;`. A flake's source
  tree cannot reach outside itself, so the build takes such a package from
  this argument. A path inside `src` needs no entry.
- `fetchurl`, a replacement for nixpkgs' fetchurl, for credentials or
  mirrors. It takes the arguments of nixpkgs' fetchurl.

The downloads are fetched by the shared library of the nix-purifiers,
[purifier](https://github.com/nix-purifiers/purifier), which also holds
the wheel selection.

Every source uv.lock records builds:

- Packages from an index install from the wheel for the system and Python
  of the build, or else build from their sdist.
- Packages from git build from a checkout of the locked commit, with its
  submodules and from the `subdirectory` uv.lock names. A project that
  reads its version from git with setuptools-scm or hatch-vcs gets the
  version uv.lock records, because the checkout has no repository.
- Packages from a URL install the wheel, or build the archive.
- Packages from a local directory, sdist or wheel build or install from
  `src` or `pathSources`.

## Develop offline

```zsh
nix run github:nix-purifiers/uv-purifier -- sync
```

`sync` installs the project's `.venv` with no network, from the files Nix
fetched and built: the dependencies, including the default dependency
groups, with their hashes, the packages from git, URLs and local paths from
the wheels Nix built, and the workspace members and editable path
dependencies as editable installs. Run commands in it with
`uv run --no-sync`, or with `.venv/bin/` directly. An editor or language
server that uses the project's `.venv`, such as pyright, Pylance or
basedpyright, resolves every import from it. The checks run pyright on a
synced fixture to keep that so.

`sync` runs uv with a cache of its own, under
`$XDG_CACHE_HOME/uv-purifier`. With the usual uv cache, which holds index
data from online runs, uv picks distributions from that index data even
with no index configured, and then cannot download them offline.

## Publish

```zsh
nix run github:nix-purifiers/uv-purifier -- publish -- --token "$PYPI_TOKEN"
```

`publish` builds each workspace member's package with Nix and uploads what
Nix built with `uv publish`. Arguments after `--` go to `uv publish`.
`--package <member>` limits it to some members.

## Limits

- The build runs on Linux, for x86_64 and aarch64. The wheel selection
  (the shared library's `wheels`) reads the Linux platform tags of a wheel against
  the glibc of the package set. uv.lock and `uv-purifier.lock.json` cover
  every platform, so a lock made anywhere builds on both.
- A build backend reports its added requirements for the platform of the
  lock run. A backend that asks for different packages on another platform
  makes that platform's build fail with uv's error naming the missing
  package.
- uv itself does not install from the locked files offline: with no
  network, `uv sync` installs a registry package only from the URL in
  uv.lock or from uv's own cache, whose layout is internal to uv. The build
  and `sync` therefore install with `uv pip install --require-hashes`
  against a directory of the locked files, which checks every file against
  the hashes in uv.lock.

## Projects tried

- [Flask](https://github.com/pallets/flask) at commit `49943b5`
  (2026-10-30): a flit-core build with 79 locked packages, compiled wheels
  (markupsafe, cffi, cryptography), packages built from sdists, and
  dependency groups for tests, typing and docs. A lock took about 13
  seconds with an empty uv cache and 7 to 10 seconds with a warm one. The
  Nix build made Flask's environment and package. `sync` installed the
  development environment offline, and Flask's 494 tests pass in it with
  `uv run --no-sync pytest`. pyright resolved every installed import from
  `.venv`. After `uv lock --upgrade-package pytest`, `sync` refused the
  stale lockfile and named `uv-purifier lock`, and the relock and a second
  `sync` brought pytest 9.2.0. The checks build this commit on x86_64 and
  aarch64 and run its tests (`tests/real-world/flask`).

  Flask led to these changes. The lock run asks each PEP 517 hook of a
  backend on its own, because maturin's bootstrap backend fails in its
  editable hook alone. It downloads a file again when its hash does not
  match, because a download now and then came back with other bytes.
  `sync` uses a uv cache of its own, as described above. `sync` and
  `publish` check the lockfile before they start Nix, so their errors name
  the project's files.

`docs/development/` describes the design and the tests.

The purifiers follow the design of
[sbt-nix-backend](https://github.com/nix-purifiers/sbt-purifier): the build
tool keeps planning the build, a lock run records what it needs, and Nix
builds from the lockfile in its sandbox. The purifier idea was inspired by
nixcloud's [cargo (libnix)](https://github.com/nixcloud/cargo).
