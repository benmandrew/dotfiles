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
