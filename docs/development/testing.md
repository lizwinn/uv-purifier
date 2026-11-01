# Testing

`nix flake check` runs every check for the system it runs on. CI
(`.github/workflows/check.yml`) runs it on an x86_64 and an arm64 Linux
runner. On one system:

```zsh
nix build '.#checks.x86_64-linux.simple'
```

The checks (`tests/default.nix`) build in the sandbox. The only network
access is the fixed-output fetches of locked files and git checkouts.

## The checks of the purifier contract

- `conformance-stale`, `conformance-tampered`, `conformance-missing` and
  `conformance-malformed` (`tests/negative.nix`) break a copy of the simple
  fixture in each way a developer breaks the lockfiles (a stale uv.lock, a
  dependency added without `uv lock`, a tampered hash, a missing entry or
  lockfile, a malformed lockfile, another format version) and check with
  nix-instantiate that the error names the command to run.
- `conformance-offline` runs `uv-purifier prefetch` on a copy of
  `tests/fixtures/sources` with the inputs Nix built, in the sandbox, which
  has no network. It runs a script of the `.venv` that `prefetch`
  installed, edits a member's source, runs the script again to see the
  edit through the editable install, and runs pyright against `.venv`, as
  an editor would. `offline-workspace` does the same for the workspace
  fixture.
- `conformance-external` builds the simple fixture from a source without
  its purifier lockfile, with the lockfile given outside it.
- `conformance-relock` is a CI job: it runs `tests/relock-fixtures.sh` and
  fails when a lockfile differs from the committed one.
- `conformance-rebuild` is a CI job: it builds `rebuild-release` and
  `rebuild-package`, two outputs of the simple fixture, and builds them
  again with `nix build --rebuild`, which fails when they differ.

## The other checks

- `simple` builds `tests/fixtures/simple`, a hatchling project. docopt has
  only an sdist and is built with the locked setuptools. markupsafe
  installs its compiled wheel for the system, and the script calls its
  compiled extension.
- `workspace` builds `tests/fixtures/workspace`, a virtual root with a
  setuptools member and a flit-core member that depends on it, and runs the
  script of the root's package.
- `sources` builds `tests/fixtures/sources`, whose dependencies come from
  git (attrs at a tag, built with hatch-vcs), a GitHub archive URL (six), a
  wheel URL (idna), a local directory, a local sdist and a local wheel.
- `outside` builds `tests/fixtures/outside/app`, which depends on the
  editable path `../shared`, given through `pathSources`.
- `release` checks that the release holds each member's sdist and wheel
  under the names `release.artifacts` gives.
- `tests` runs the workspace fixture's test command through `tests`.
- `fetches` checks that `fetches` lists file and git entries.
- `outputs` reads the names of the release's artifacts and the packages'
  scripts at evaluation time, which builds nothing, and compares them with
  what the fixtures make.
- `nix-library` (`tests/nix-library.nix`) tests wheel selection and the
  refusal of a lockfile that no longer matches uv.lock.
- `unit` runs `tests/unit`: the lock tool's parsing, its URL-to-file-name
  logic, its lockfile check, and split_requirements.py.
- `flask` builds Flask at a pinned commit (`tests/real-world/flask`) from
  its own source with the lockfile kept outside it, runs its test suite
  through `tests`, and runs `uv-purifier prefetch` and the test suite
  offline.
- `cli` runs the command's help.
- `treefmt` checks the formatting of the Nix files. `nix fmt` applies it.

## Relocking the fixtures

`tests/relock-fixtures.sh` runs `uv lock` and `uv-purifier lock` in every
fixture, with the uv of the flake's package set. It needs PyPI and GitHub.
A relock resolves the build requirements as of the time each lockfile
records, so it reproduces the lockfiles byte for byte.

`tests/real-world/flask/uv-purifier.lock.json` is what `uv-purifier lock`
wrote in a checkout of Flask at the pinned commit.

The local files of `tests/fixtures/sources/vendor` are built from the
`*-src` directories beside them, as their pyproject.toml files say.
`uv build --out-dir` also writes a `.gitignore` of `*` into `vendor/`,
which has to be deleted afterwards.
