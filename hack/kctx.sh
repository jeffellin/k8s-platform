# kctx: pick a cluster from _talos/ and point KUBECONFIG at it, like kubectx. SOURCE this file, do not run it
# (a child process cannot change your shell's environment):
#
#   echo 'source ~/homelab/k8s-platform/hack/kctx.sh' >> ~/.bashrc
#
#   kctx              pick from a list (fzf if installed, else a numbered menu)
#   kctx <name>       use _talos/<name>/kubeconfig in THIS shell (tab-completes); fetches it from the manager if missing
#   kctx -            switch back to the previous cluster
#   kctx -c           show the current cluster
#   kctx -l           list clusters (local kubeconfigs, marking the current one)
#   kctx -u           unset KUBECONFIG (back to ~/.kube/config)
#
# Only sets $KUBECONFIG for the current shell; ~/.kube/config is never modified. Clusters = directories in
# $KCTX_DIR (default: <repo>/_talos) that contain a `kubeconfig`. Missing ones are fetched with hack/get-kubeconfig.sh.

_KCTX_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
: "${KCTX_DIR:=$_KCTX_ROOT/_talos}"

_kctx_list() {
  local d
  for d in "$KCTX_DIR"/*/; do
    [ -f "${d}kubeconfig" ] && basename "$d"
  done
}

_kctx_current() {
  case "${KUBECONFIG:-}" in
    "$KCTX_DIR"/*/kubeconfig) local p="${KUBECONFIG%/kubeconfig}"; echo "${p##*/}" ;;
    "") return 1 ;;
    *) echo "${KUBECONFIG}"; return 0 ;;   # something else: show it as is
  esac
}

_kctx_use() {
  local name="$1" f="$KCTX_DIR/$1/kubeconfig"
  if [[ ! "$name" =~ ^[a-z0-9]([a-z0-9-]*[a-z0-9])?$ ]]; then echo "kctx: bad cluster name '$name'" >&2; return 2; fi
  if [ ! -f "$f" ]; then
    echo "kctx: no local kubeconfig for '$name'; fetching from the manager..." >&2
    # pin the manager explicitly: get-kubeconfig.sh would otherwise fall back to $KUBECONFIG, i.e. the cluster picked last
    "$_KCTX_ROOT/hack/get-kubeconfig.sh" "$name" --manager-kubeconfig "${MANAGER_KUBECONFIG:-$KCTX_DIR/lab-manager/kubeconfig}" || { echo "kctx: could not fetch '$name'" >&2; return 1; }
  fi
  local cur; cur="$(_kctx_current 2>/dev/null || true)"
  [ -n "$cur" ] && [ "$cur" != "$name" ] && export KCTX_PREV="$cur"
  export KUBECONFIG="$f"
  echo "kctx: using $name ($f)"
}

_kctx_pick() {
  local names cur choice
  names="$(_kctx_list)"
  [ -n "$names" ] || { echo "kctx: no clusters with a kubeconfig in $KCTX_DIR" >&2; return 1; }
  cur="$(_kctx_current 2>/dev/null || true)"
  if command -v fzf >/dev/null 2>&1; then
    choice="$(printf '%s\n' "$names" | fzf --height=40% --reverse --prompt="cluster> " --header="current: ${cur:-none}")" || return 1
  else
    local PS3="cluster (current: ${cur:-none})> " n
    select n in $names; do [ -n "$n" ] && { choice="$n"; break; }; done
  fi
  [ -n "$choice" ] && _kctx_use "$choice"
}

kctx() {
  case "${1:-}" in
    "")        _kctx_pick ;;
    -h|--help) sed -n '2,13p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//' ;;
    -l)        local c; c="$(_kctx_current 2>/dev/null || true)"; _kctx_list | while read -r n; do [ "$n" = "$c" ] && echo "* $n" || echo "  $n"; done ;;
    -c)        _kctx_current || { echo "kctx: KUBECONFIG is not set (using ~/.kube/config)" >&2; return 1; } ;;
    -u)        unset KUBECONFIG; echo "kctx: KUBECONFIG unset" ;;
    -)         [ -n "${KCTX_PREV:-}" ] && _kctx_use "$KCTX_PREV" || { echo "kctx: no previous cluster" >&2; return 1; } ;;
    -*)        echo "kctx: unknown option $1 (see kctx --help)" >&2; return 2 ;;
    *)         [ $# -eq 1 ] || { echo "kctx: one cluster name only" >&2; return 2; }; _kctx_use "$1" ;;
  esac
}

_kctx_complete() { COMPREPLY=( $(compgen -W "$(_kctx_list) -l -c -u -" -- "${COMP_WORDS[COMP_CWORD]}") ); }
complete -F _kctx_complete kctx 2>/dev/null || true

# Run directly (hack/kctx.sh ...) instead of sourced: a child process cannot set your shell's KUBECONFIG, so say so instead of silently doing nothing.
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  echo "kctx.sh must be sourced, not run:  source ${BASH_SOURCE[0]}   (then: kctx <name>)" >&2
  exit 1
fi
