# Testing

`nix flake check` runs every check for the system it runs on. CI
(`.github/workflows/check.yml`) runs it on an x86_64 and an arm64 Linux
runner. On one system:

```zsh
nix build '.#checks.x86_64-linux.simple'
```

The checks (`tests/default.nix`) build in the sandbox. The only network
access is the fixed-output fetches of locked files and git checkouts.

- `simple` builds `tests/fixtures/simple`, a hatchling project. docopt has
  only an sdist and is built with the locked setuptools. markupsafe
  installs its compiled wheel for the system, and the script calls its
  compiled extension.
- `workspace` builds `tests/fixtures/workspace`, a virtual root with a
  setuptools member and a flit-core member that depends on it, and runs the
  script of the root's environment.
- `workspace-package` checks that a member's package holds its sdist and
  wheel.
- `sources` builds `tests/fixtures/sources`, whose dependencies come from
  git (attrs at a tag, built with hatch-vcs), a GitHub archive URL (six),
  a local directory, a local sdist and a local wheel.
- `outside` builds `tests/fixtures/outside/app`, which depends on the
  editable path `../shared`, given through `pathSources`.
- `sync-workspace` and `sync-sources` run `uv-purifier sync` on a copy of a
  fixture with the inputs Nix built, run a script of the `.venv` it
  installed, edit a member's source, and run the script again to see the
  edit through the editable install.
- `outputs` reads the names of packages' artifacts and environments'
  scripts at evaluation time, which builds nothing, and compares them with
  what the fixtures make.
- `nix-library` (`tests/nix-library.nix`) tests wheel selection and the
  refusal of a lockfile that no longer matches uv.lock.
- `negative` (`tests/negative.nix`) breaks a copy of the simple fixture in
  each way a developer breaks the lockfiles (a stale uv.lock, a dependency
  added without `uv lock`, a tampered hash, a missing entry, a malformed or
  missing lockfile, another format version) and checks with
  nix-instantiate that the error names the command to run.
- `unit` runs `tests/unit`: the lock tool's parsing, its URL-to-file-name
  logic, its lockfile check, and split_requirements.py.
- `flask` builds Flask at a pinned commit (`tests/real-world/flask`), runs
  `uv-purifier sync` and Flask's test suite offline.
- `cli` runs the command's help.
- `treefmt` checks the formatting of the Nix files. `nix fmt` applies it.

## Relocking the fixtures

`tests/relock-fixtures.sh` runs `uv lock` and `uv-purifier lock` in every
fixture, with the uv of the flake's package set. It needs PyPI and GitHub.
A relock resolves the build requirements as of the time each lockfile
records, so it reproduces the lockfiles byte for byte; the `relock` job of
CI runs it and fails on any difference.

`tests/real-world/flask/uv-purifier.lock.json` is what `uv-purifier lock`
wrote in a checkout of Flask at the pinned commit.

The local files of `tests/fixtures/sources/vendor` are built from the
`*-src` directories beside them, as their pyproject.toml files say.
`uv build --out-dir` also writes a `.gitignore` of `*` into `vendor/`,
which has to be deleted afterwards.
