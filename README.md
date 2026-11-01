# uv-purifier

uv-purifier lets Nix build a [uv](https://docs.astral.sh/uv/) project in its
sandbox, offline, from the project's lockfiles. You do not commit generated
Nix files to the project.

uv.lock already pins every dependency of the project with its URL and hash,
and the Nix library reads it directly. What uv.lock leaves out are the build
requirements: the build backend of each workspace member, and the packages
needed to build a dependency from its sdist. `uv-purifier lock` resolves
those with uv and writes them to `uv-purifier.lock.json` beside uv.lock.

## Lock

From the directory that holds uv.lock:

```zsh
nix run github:nix-purifiers/uv-purifier -- lock
```

Commit `uv-purifier.lock.json`. Run it again whenever uv.lock or the
`[build-system]` table of a workspace member changes. The Nix build refuses
a `uv-purifier.lock.json` that no longer matches them.

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

`buildUvProject` takes `python` (default `python3`), which must satisfy the
project's `requires-python`, and `fetchurl`, a replacement fetcher for
credentials or mirrors (`nix/lib/fetch.nix`).

## Publish

```zsh
nix run github:nix-purifiers/uv-purifier -- publish -- --token "$PYPI_TOKEN"
```

`publish` builds each workspace member's package with Nix and uploads what
Nix built with `uv publish`. Arguments after `--` go to `uv publish`.
`--package <member>` limits it to some members.

## Limits

- Dependencies from git or from a local path are not supported yet. Both
  commands say so when uv.lock has one.
- The build runs on Linux (x86_64 and aarch64).
- `uv sync` and `uv run` keep downloading the usual way. With no network,
  uv installs a registry package only from the URL in uv.lock or from its
  own cache, so the build installs from the locked files with
  `uv pip install --require-hashes` instead.

`docs/development/` describes the design and the tests.

The purifier idea was inspired by nixcloud's
[cargo (libnix)](https://github.com/nixcloud/cargo).
