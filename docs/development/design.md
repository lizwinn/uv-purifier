# Design

## Two lockfiles

uv.lock pins every package the project installs, including development
groups and optional dependencies, for every platform: each package has its
wheels and its sdist, with URLs and SHA-256 hashes. The Nix library reads
uv.lock with `builtins.fromTOML` (`nix/lib/lock.nix`).

uv.lock does not pin build requirements. A workspace member's
`[build-system].requires` is resolved by uv's build isolation at build time,
and so are the build requirements of a dependency that installs from its
sdist. `uv-purifier lock` (`src/uv_purifier.py`) fills that gap:

1. It collects the build requirements of every workspace member with a
   build, from the member's pyproject.toml.
2. It downloads the sdist of every dependency that has no wheel tagged
   `none-any` and reads the build requirements from the pyproject.toml in
   the sdist. A package without that table gets uv's default,
   `setuptools>=40.8.0`. Such a dependency may have to be built on some
   system, and the Nix build decides which systems.
3. It resolves each distinct set of build requirements by running
   `uv lock` on a throwaway virtual project that depends on them. The
   throwaway project copies the index settings of the root pyproject.toml.
   The result covers every platform, like uv.lock does.
4. It repeats step 2 for the packages of each resolved set, because a build
   requirement can itself have only an sdist.

`uv-purifier.lock.json` records:

- `artifacts`: every file of the resolved build requirements, as download
  entries of the shared purifier library: `path` (the file name), `url`
  and an SRI `hash`.
- `buildRequirements`: each distinct set, with its resolved packages and
  the file names of their wheels and sdist. A set that did not resolve has
  `error` instead, and the Nix build reports it only if it has to build
  that package.
- `builds`: for each package that may be built, `"<name>==<version>"`, the
  index of its set.
- `inputsHash`: a hash over uv.lock and every member's pyproject.toml. The
  Nix library computes the same hash and refuses the lockfile when they
  differ.

## Choosing the files for a system

`nix/lib/wheels.nix` decides from a wheel's file name whether it installs
with the build's Python on the build's system (PEP 425 tags, manylinux
1, 2010, 2014 and `2_N` against the glibc of the package set, `abi3`). For
each package, `nix/lib/build-uv-project.nix` takes its wheels that install,
or else its sdist and the build of it. A build adds the files of its set of
build requirements, chosen the same way, and the builds those need in turn.
Every chosen file is fetched as a fixed-output derivation and linked into
one flat directory, the wheelhouse.

uv makes the final choice among the fetched wheels when it installs. When a
wheel that `wheels.nix` accepts is one uv rejects, uv tries to build the
sdist, which is missing from the wheelhouse, and the build fails with uv's
error.

## Installing in the sandbox

uv runs with `UV_OFFLINE`, `UV_NO_INDEX` and `UV_FIND_LINKS` pointing at the
wheelhouse, and with the Python of the package set (`UV_PYTHON`,
`UV_PYTHON_DOWNLOADS=never`).

- A member's package is `uv build --package <member>`, which builds its
  sdist and then its wheel from the sdist, in an isolated environment that
  takes the build backend from the wheelhouse.
- A member's environment is `uv export --frozen --no-dev --package <member>
  --no-emit-workspace`, a requirements file with every hash from uv.lock,
  installed with `uv pip install --require-hashes` into a new virtual
  environment, followed by the wheels of the member and of the members it
  depends on.

`uv sync` cannot do this step. With no network, uv installs a registry
package of uv.lock only from the URL in uv.lock or from its cache, and
ignores `--find-links`. The cache's layout is internal to uv.

## The interpreter

The Python comes from nixpkgs (`python ? python3`). uv never downloads one
in the build. The lockfiles record no Python version, because uv.lock
covers every version that `requires-python` allows.
