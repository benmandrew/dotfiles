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
          ];
        };
      }
    );
}
