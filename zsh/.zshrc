# Time startup - also uncomment 
# zmodload zsh/zprof

# Path to your oh-my-zsh installation.
export ZSH="$HOME/.oh-my-zsh"

# See https://github.com/ohmyzsh/ohmyzsh/wiki/Themes
ZSH_THEME="eastwood"

zstyle ':omz:plugins:nvm' lazy yes

# Example format: plugins=(rails git textmate ruby lighthouse)
plugins=(git nvm)

source $ZSH/oh-my-zsh.sh

# User configuration

# Preferred editor for local and remote sessions
# if [[ -n $SSH_CONNECTION ]]; then
#   export EDITOR='vim'
# else
#   export EDITOR='mvim'
# fi


export PATH="$PATH:/usr/local/bin"
export PATH="$PATH:$HOME/.local/bin"
export PATH="$PATH:/usr/local/go/bin"
export PATH="$PATH:$HOME/.cargo/bin"
export PATH="$PATH:$HOME/projects/tools/dafny"

export COLORTERM=truecolor

alias vim="nvim"
export VISUAL=nvim
export EDITOR="$VISUAL"

export PAGER="most -w -t4"

alias ls="eza --long --no-permissions --numeric --group-directories-first"
alias lsa="eza"
alias gst="git st"
alias gs="git st"
alias gsv="git sv"
alias gbv="git bv"
alias grv="git rv"
alias gch="git ch"
alias ga="git add -A"
alias gd="git diff"
alias gdc="git diff --cached"
alias gll="git ll"
alias gdl="git dl"
alias grb="git rebase"
unalias gl

alias python="python3"

export HISTFILE="$HOME/.zsh_history"
export HISTSIZE=1000000000
export SAVEHIST=1000000000
setopt EXTENDED_HISTORY

eval "$(zoxide init zsh --cmd cd)"

[ -f ~/.fzf.zsh ] && source ~/.fzf.zsh

# BEGIN opam configuration
# This is useful if you're using opam as it adds:
#   - the correct directories to the PATH
#   - auto-completion for the opam binary
# This section can be safely removed at any time if needed.
[[ ! -r '/home/y19056ba/.opam/opam-init/init.zsh' ]] || source '/home/y19056ba/.opam/opam-init/init.zsh' > /dev/null 2> /dev/null
# END opam configuration

if [ "$TMUX" = "" ]; then tmux; fi

[ -f "/home/y19056ba/.ghcup/env" ] && . "/home/y19056ba/.ghcup/env" # ghcup-env
