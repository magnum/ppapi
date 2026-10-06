# Source from ~/.zshrc so `bin/import` tab-completes Excel paths.
#   source /Users/magnum/projects/ppapi/completions/ppapi.zsh
_dir="${${(%):-%x}:A:h}"
fpath=("$_dir" ${fpath})
autoload -Uz _ppapi-import
compdef _ppapi-import bin/import ./bin/import
unset _dir
