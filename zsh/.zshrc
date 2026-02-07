# ---------------- Oh My Zsh ----------------
export ZSH="$HOME/.oh-my-zsh"

# Disable Oh My Zsh theme – Pure will be the prompt
ZSH_THEME=""

# Load Oh My Zsh
source "$ZSH/oh-my-zsh.sh"

# ---------------- Pure (Homebrew install) ----------------
# Make sure zsh can find Pure's functions
fpath+=("$(brew --prefix)/share/zsh/site-functions")

# Initialize the prompt system
autoload -U promptinit; promptinit

# Activate Pure
prompt pure

# ---------------- (Optional) Plugins via zplug ----------------
# Only keep zplug for other plugins, not Pure itself

export ZPLUG_HOME="/opt/homebrew/opt/zplug"
source "$ZPLUG_HOME/init.zsh"

# Syntax highlighting
zplug "zsh-users/zsh-syntax-highlighting", as:plugin, defer:2

# Autosuggestions
zplug "zsh-users/zsh-autosuggestions", as:plugin, defer:2

if ! zplug check --verbose; then
  zplug install
fi

zplug load

# User scripts (from dotfiles)
export PATH="$HOME/bin:$PATH"

# Added by Antigravity
export PATH="/Users/eftikharazim/.antigravity/antigravity/bin:$PATH"
