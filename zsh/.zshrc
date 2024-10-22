# Path to your oh-my-zsh installation.
export ZSH="$HOME/.oh-my-zsh"

# See https://github.com/ohmyzsh/ohmyzsh/wiki/Themes
ZSH_THEME="eastwood"

# Example format: plugins=(rails git textmate ruby lighthouse)
plugins=(git tmux)

source $ZSH/oh-my-zsh.sh

# User configuration

# Preferred editor for local and remote sessions
# if [[ -n $SSH_CONNECTION ]]; then
#   export EDITOR='vim'
# else
#   export EDITOR='mvim'
# fi

# source /opt/homebrew/opt/chruby/share/chruby/chruby.sh
# source /opt/homebrew/opt/chruby/share/chruby/auto.sh
# chruby ruby-3.1.2

# export PATH=$HOME/Library/Python/3.10/bin:$PATH
# export PATH=~/bin:$PATH
# export PATH=/usr/local/opt/llvm/bin:$PATH
# export PATH=/opt/homebrew/opt/openjdk/bin:$PATH
# export PATH=~/projects/storm/build/bin:$PATH

# export JAVA_DIR=/opt/homebrew/opt/openjdk
# export JAVA_HOME=/opt/homebrew/opt/openjdk/bin/java

# export LDFLAGS='-L/usr/local/opt/llvm/lib -Wl,-rpath,/usr/local/opt/llvm/lib'

# export LIBRARY_PATH="$LIBRARY_PATH:$(brew --prefix)/lib"

export PATH="/usr/local/bin:$PATH"
export PATH="$HOME/.cargo/bin:$PATH"

export COLORTERM=truecolor

export VISUAL=vim
export EDITOR="$VISUAL"

alias ls="eza -l"
alias gst="git st"
alias gsv="git sv"
alias gbv="git bv"
alias grv="git rv"
alias gch="git ch"
alias gdd="git add"
alias gll="git ll"
alias gdl="git dl"
alias grb="git rebase"
unalias gl

alias vim="nvim"

export HISTFILE="$HOME/.zsh_history"
export HISTSIZE=1000000000
export SAVEHIST=1000000000
setopt EXTENDED_HISTORY

source /opt/ros/humble/setup.zsh

export PATH="$HOME/.local/bin:$PATH"
eval "$(zoxide init zsh --cmd cd)"

[ -f ~/.fzf.zsh ] && source ~/.fzf.zsh


# BEGIN opam configuration
# This is useful if you're using opam as it adds:
#   - the correct directories to the PATH
#   - auto-completion for the opam binary
# This section can be safely removed at any time if needed.
[[ ! -r '/home/y19056ba/.opam/opam-init/init.zsh' ]] || source '/home/y19056ba/.opam/opam-init/init.zsh' > /dev/null 2> /dev/null
# END opam configuration
