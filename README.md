## Bootstrap

Supported on macOS ARM64, Ubuntu x86\_64 and Debian ARM64.

```bash
$ ./scripts/install.sh
$ chezmoi init --apply git@github.com:benmandrew/dotfiles.git
```

## Manual steps

```bash
$ atuin register    # or `atuin login` after the first machine
$ atuin import auto
```

Back up `~/.local/share/atuin/key` in a password manager.

## Development

```bash
$ nix develop    # or `direnv allow` once
$ make hooks
$ make
```
