# Testing

`nix flake check` runs every check. On one system:

```zsh
nix build '.#checks.x86_64-linux.simple'
```

The checks (`tests/default.nix`) build in the sandbox. The only network
access is the fixed-output fetches of locked files.

- `simple` builds `tests/fixtures/simple`, a hatchling project whose
  dependency docopt has only an sdist, and runs its script.
- `workspace` builds `tests/fixtures/workspace`, a virtual root with a
  setuptools member and a flit-core member that depends on it, and runs the
  script of the root's environment.
- `workspace-package` checks that a member's package holds its sdist and
  wheel.
- `nix-library` (`tests/nix-library.nix`) tests wheel selection and the
  refusal of a lockfile that no longer matches uv.lock.
- `cli` runs the command's help.
- `treefmt` checks the formatting of the Nix files. `nix fmt` applies it.

## Relocking the fixtures

`tests/relock-fixtures.sh` runs `uv lock` and `uv-purifier lock` in every
fixture, with the uv of the flake's package set. It needs PyPI. Relocking
picks up new releases of build requirements such as hatchling and
setuptools, so the fixture lockfiles change only when someone relocks them.
