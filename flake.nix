{
  description = "Dev shell for chezmoi dotfiles: formatters and linters used by make fmt/lint";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs =
    {
      self,
      nixpkgs,
      flake-utils,
    }:
    flake-utils.lib.eachDefaultSystem (
      system:
      let
        pkgs = import nixpkgs { inherit system; };
        sshconfig-lint = pkgs.rustPlatform.buildRustPackage rec {
          pname = "sshconfig-lint";
          version = "0.4.0";
          src = pkgs.fetchCrate {
            inherit pname version;
            hash = "sha256-jk7UO0EXAlznDkrUbsMHJfz+4/0pVp6bn/KB6upV6sI=";
          };
          cargoHash = "sha256-AlNrND4Dejud0PuqV2RvyNHbjun/Fq2lkg6ud17GwoY=";
          meta = with pkgs.lib; {
            description = "Linter for OpenSSH client config files";
            homepage = "https://github.com/Noah4ever/sshconfig-lint";
            license = licenses.mit;
            mainProgram = "sshconfig-lint";
          };
        };
      in
      {
        devShells.default = pkgs.mkShell {
          packages = with pkgs; [
            chezmoi
            stylua
            shfmt
            shellcheck
            lua54Packages.luacheck
            actionlint
            taplo
            typos
            checkmake
            sshconfig-lint
          ];
        };
      }
    );
}
