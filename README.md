# uv-purifier

uv-purifier lets Nix build a [uv](https://docs.astral.sh/uv/) project in its
sandbox, offline, from the project's lockfiles. You do not commit generated
Nix files to the project.

uv.lock already pins every dependency of the project with its URL and hash,
and the Nix library reads it directly. What uv.lock leaves out are the build
requirements: the build backend of each workspace member, and the packages
needed to build a dependency from its source. `uv-purifier lock` resolves
those with uv and writes them to `uv-purifier.lock.json` beside uv.lock.
uv-purifier meets the [purifier contract](https://github.com/nix-purifiers/purifier/blob/main/CONTRACT.md)
that every nix-purifier meets.

## Quickstart

From the directory that holds uv.lock:

```zsh
nix run github:nix-purifiers/uv-purifier -- lock
```

Commit `uv-purifier.lock.json`. Then build the project from a flake with
the builder in the flake's library:

```nix
{
  inputs.uv-purifier.url = "github:nix-purifiers/uv-purifier";
  inputs.nixpkgs.follows = "uv-purifier/nixpkgs";

  outputs = { nixpkgs, uv-purifier, ... }:
    let
      system = "x86_64-linux";
      pkgs = nixpkgs.legacyPackages.${system};
      project = uv-purifier.lib.uv-purifier.buildUvProject {
        inherit pkgs;
        src = ./.;
      };
    in
    {
      # A virtual environment with the member `app`, its dependencies and
      # its scripts in bin/.
      packages.${system}.default = project.packages.app;
      checks.${system}.tests = project.tests;
    };
}
```

`buildUvProject { pkgs, src, ... }` returns:

- `packages.<member>`: for each workspace member, a virtual environment
  with the member and its runtime dependencies, and its scripts in `bin/`.
  `packages.<member>.scripts.<script>` names each script. A virtual
  workspace root has a package too.
- `tests`: the project's test command (`testCommand`, by default
  `[ "pytest" ]`), run in the sandbox from a copy of `src`, in an
  environment with every member and the default dependency groups.
- `release`: the sdist and wheel of every member with a build, which
  `uv-purifier publish` uploads. `release.artifacts."<file name>"` names
  each file, such as `release.artifacts."app-2.0.0-py3-none-any.whl"`.
- `fetches`: the download entries of the
  [purifier](https://github.com/nix-purifiers/purifier) library that the
  build fetches for the system: a file entry per locked file, and a git
  entry per git checkout. SBOM, license and vulnerability tools read it.

Every name in the result is known when Nix evaluates, from the lockfiles,
without building anything. `uv-purifier lock` records the file names and
scripts of each member by building it once, so scripts that a setup.py
defines are included.

`buildUvProject` also takes:

- `fetchers`, which goes to the purifier library's `fetchEntry` and `tree`,
  such as `fetchers.fetchurl` for a company mirror or credentials.
- `python` (default `pkgs.python3`), which must satisfy the project's
  `requires-python`.
- `lockFile` (default `src + "/uv-purifier.lock.json"`). A file given
  outside `src` replaces any copy in it, so a packaging flake can build a
  project its author does not change, with the purifier lockfile kept
  beside the packaging; uv.lock stays in the project. Every command takes
  `--lockfile <path>` for the same purpose.

`lib.uv-purifier.readLock { src, lockFile ? ... }` reads uv.lock and the
purifier lockfile into the lock in memory of the purifier contract,
`{ purifier, entries, outputs, problems }`, which tools that read every
purifier, such as an SBOM generator, read in one shape. A compiled wheel's
entry carries the `systems` its platform tags name. `buildUvProject` checks
it with the purifier library's `checkLock` and takes the downloads of its
system from `entriesFor`.
- `pathSources`, the local packages that uv.lock names by a path outside
  `src`, such as `pathSources."../shared" = ../shared;`. A flake's source
  tree cannot reach outside itself. A path inside `src` needs no entry.
- `testCommand`, the command of `tests`.

## Everyday loop

```zsh
nix run github:nix-purifiers/uv-purifier -- prefetch
uv run --no-sync pytest
```

`prefetch` realizes in the Nix store everything development needs on this
system, keeps it alive with a garbage-collector root at
`.uv-purifier/prefetch` (add `.uv-purifier/` to `.gitignore`), and
installs the project's `.venv` from it: the dependencies, including the
default dependency groups, with their hashes; the packages from git, URLs
and local paths from the wheels Nix built; and the workspace members and
editable path dependencies as editable installs. Run the project and its
tests with `uv run --no-sync`, or with `.venv/bin/` directly. An edit to a
member shows at once.

To add or upgrade a dependency, use uv as usual, which needs the network,
then relock and prefetch again:

```zsh
uv add requests            # or: uv lock --upgrade-package requests
nix run github:nix-purifiers/uv-purifier -- lock
nix run github:nix-purifiers/uv-purifier -- prefetch
```

A relock resolves the build requirements as of the time the lockfile
records, so it keeps their versions and reproduces the lockfile byte for
byte when nothing else changed. `uv-purifier lock --upgrade` resolves them
anew.

`nix run github:nix-purifiers/uv-purifier -- publish -- --token "$TOKEN"`
uploads the `release` that Nix built, with `uv publish`; arguments after
`--` go to `uv publish`, and `--package <member>` limits it to members.

## Offline work

After `prefetch`, `uv run --no-sync`, the tests and the editor work with
the network cut off. `uv run` without `--no-sync` and `uv sync` do not:
with no network, uv installs a registry package only from the URL in
uv.lock or from its own cache, whose layout is internal to uv. Setting
`UV_NO_SYNC=1` makes `--no-sync` the default.

`prefetch` runs uv with a cache of its own, under
`$XDG_CACHE_HOME/uv-purifier`. With the usual uv cache, which holds index
data from online runs, uv picks distributions from that index data even
with no index configured, and then cannot download them offline.

## Editor

An editor or language server that uses the project's `.venv`, such as
pyright, Pylance or basedpyright, resolves every import from it after
`prefetch`, with no network. The checks run pyright on a prefetched
fixture to keep that so.

## Errors and fixes

| What happened | The error says | Fix |
| --- | --- | --- |
| uv.lock changed, or a dependency was added to pyproject.toml without `uv lock` | `uv-purifier.lock.json was made for another uv.lock or another pyproject.toml` | If pyproject.toml changed, run `uv lock`; then run `uv-purifier lock`. |
| uv-purifier.lock.json was edited by hand or by a merge | `was changed after uv-purifier lock wrote it` | `uv-purifier lock` |
| uv-purifier.lock.json is not valid JSON | `is not valid JSON` | `uv-purifier lock` |
| uv-purifier.lock.json is missing | `does not exist` | `uv-purifier lock`, and commit the file |
| The lockfile has another format version | `has lock format version` | `uv-purifier lock` |
| A package must be built from its sdist on this system, but the lockfile has no build requirements for it | `has no build requirements for` | `uv-purifier lock` |
| A downloaded file did not match the hash in uv.lock | `has sha256 …, but uv.lock says …` | The lock run tries again twice; if it keeps failing, check the network path |
| uv.lock names a local path outside `src` | `which is outside src. Pass it in pathSources` | Pass the path in `pathSources` |

`prefetch` and `publish` check the lockfile before they start Nix, so their
errors name the project's own files.

## Sources supported and refused

Every source kind uv.lock records builds:

- Packages from an index install from the wheel for the system and Python
  of the build, or else build from their sdist.
- Packages from git build from a checkout of the locked commit, with its
  submodules and from the `subdirectory` uv.lock names. A project that
  reads its version from git with setuptools-scm or hatch-vcs gets the
  version uv.lock records, because the checkout has no repository.
- Packages from a URL install the wheel, or build the archive.
- Packages from a local directory, sdist or wheel build or install from
  `src` or `pathSources`.

The build runs on Linux, for x86_64 and aarch64; the wheel selection (the
purifier library's `wheels`) reads the Linux platform tags of a wheel
against the glibc of the package set. uv.lock and `uv-purifier.lock.json`
cover every platform, so a lock made anywhere builds on both. A build
backend reports the requirements it adds at build time for the platform of
the lock run; a backend that asks for other packages on another platform
makes that platform's build fail with uv's error naming the package.

## Real-world projects

- [Flask](https://github.com/pallets/flask) at commit `49943b5`
  (2026-10-30): a flit-core build with 79 locked packages, compiled wheels
  (markupsafe, cffi, cryptography), packages built from sdists, and
  dependency groups for tests, typing and docs. A lock took about 13
  seconds with an empty uv cache and 7 to 10 seconds with a warm one. The
  Nix build made Flask's package and release, and `prefetch` installed the
  development environment offline; Flask's 494 tests pass in it with
  `uv run --no-sync pytest`, and through `tests`. pyright resolved every
  installed import from `.venv`. After `uv lock --upgrade-package pytest`,
  the stale lockfile was refused with the command to run, and the relock
  and a second `prefetch` brought pytest 9.2.0. The checks build this
  commit on x86_64 and aarch64 from Flask's own source, with the lockfile
  kept outside it (`tests/real-world/flask`).

  Flask led to these changes. The lock run asks each PEP 517 hook of a
  backend on its own, because maturin's bootstrap backend fails in its
  editable hook alone. It downloads a file again when its hash does not
  match, because a download now and then came back with other bytes.
  `prefetch` uses a uv cache of its own. `prefetch` and `publish` check the
  lockfile before they start Nix.

## Credits

The purifiers follow the design of
[sbt-nix-backend](https://github.com/nix-purifiers/sbt-purifier): the build
tool keeps planning the build, a lock run records what it needs, and Nix
builds from the lockfile in its sandbox. The purifier idea was inspired by
nixcloud's [cargo (libnix)](https://github.com/nixcloud/cargo). The
downloads go through the shared
[purifier](https://github.com/nix-purifiers/purifier) library.
`docs/development/` describes the design and the tests.
