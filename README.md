## Dependencies

The install script bootstraps all required tools for a given platform. It auto-detects the OS and architecture and delegates to the appropriate platform script.

```bash
$ ./scripts/install.sh
```

### Supported platforms

These are the platforms with a tested install script. Running `install.sh` on anything else will exit with an error.

| OS | Architecture | Distro |
|---|---|---|
| macOS | ARM64 | — |
| Linux | x86\_64 | Ubuntu |
| Linux | ARM64 | Debian |


## Dev dependencies

```bash
$ make deps
```

Alternatively, if you have [Nix](https://nixos.org) installed (`scripts/install-common.sh` installs it and enables flakes via `install_nix`), `flake.nix` provides a devShell with all formatters and linters used by `make fmt`/`make lint`:

```bash
$ nix develop
```

If you installed Nix some other way, flakes are an experimental feature not enabled by default; add this to `~/.config/nix/nix.conf` (or `/etc/nix/nix.conf`) once:

```
experimental-features = nix-command flakes
```

With [direnv](https://direnv.net) and [nix-direnv](https://github.com/nix-community/nix-direnv), the shell loads automatically on `cd` via the checked-in `.envrc`.
