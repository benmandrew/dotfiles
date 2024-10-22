# Setup fzf
# ---------
if [[ ! "$PATH" == */home/y19056ba/.fzf/bin* ]]; then
  PATH="${PATH:+${PATH}:}/home/y19056ba/.fzf/bin"
fi

source <(fzf --zsh)
