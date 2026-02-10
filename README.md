## Dependencies

```bash
$ sudo snap install chezmoi --classic
$ ssh-keygen -t ed25519 -f "/home/$(whoami)/.ssh/id_benmandrew" -N ""

$ sudo apt install zsh tmux bat

# Rust
$ curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh
$ cargo install eza

# zoxide
$ curl -sSfL https://raw.githubusercontent.com/ajeetdsouza/zoxide/main/install.sh | sh

# fzf
$ git clone --depth 1 https://github.com/junegunn/fzf.git ~/.fzf
$ ~/.fzf/install

# neovim
$ curl -LO https://github.com/neovim/neovim/releases/latest/download/nvim-linux-x86_64.tar.gz
$ sudo rm -rf /opt/nvim-linux-x86_64
$ sudo tar -C /opt -xzf nvim-linux-x86_64.tar.gz
$ rm nvim-linux-x86_64.tar.gz

# Create SSH key pair and add the public key to Gitea, then run
$ chezmoi init --apply git@ssh.git.benmandrew.com:me/dotfiles.git
```

## Dev dependencies

```bash
$ cargo install styleua
```
