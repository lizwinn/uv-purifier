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
- `nix-library` (`tests/nix-library.nix`) tests wheel selection and the
  refusal of a lockfile that no longer matches uv.lock.
- `cli` runs the command's help.
- `treefmt` checks the formatting of the Nix files. `nix fmt` applies it.

## Relocking the fixtures

`tests/relock-fixtures.sh` runs `uv lock` and `uv-purifier lock` in every
fixture, with the uv of the flake's package set. It needs PyPI and GitHub.
Relocking picks up new releases of build requirements such as hatchling and
setuptools, so the fixture lockfiles change only when someone relocks them.

The local files of `tests/fixtures/sources/vendor` are built from the
`*-src` directories beside them, as their pyproject.toml files say.
`uv build --out-dir` also writes a `.gitignore` of `*` into `vendor/`,
which has to be deleted afterwards.
