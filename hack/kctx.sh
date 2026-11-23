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
#   kctx -u           unset KUBECONFIG and TALOSCONFIG (back to ~/.kube/config)
#   kctx -p           prune local _talos/<name> dirs with no apps/talos-clusters/<name>.yaml in the repo (asks first; offline)
#   kctx -p --live    same, but compare with the TalosClusters on the manager (needs it reachable); lab-manager is never pruned
#
# Also sets $TALOSCONFIG to _talos/<name>/talosconfig when it exists (so `talosctl health` etc. target the selected
# cluster); otherwise TALOSCONFIG is unset so talosctl never talks to the previous cluster. A missing talosconfig is
# fetched from the manager on a best-effort basis.
#
# Only sets $KUBECONFIG/$TALOSCONFIG for the current shell; ~/.kube/config is never modified. Clusters = directories in
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

# Generated talosconfigs have no endpoints/nodes, so talosctl has nothing to talk to. When both are empty, fill them in
# (in the local, git-ignored file) with the host of the cluster's API server from its kubeconfig. Existing values are kept.
_kctx_talos_defaults() {
  command -v talosctl >/dev/null 2>&1 || return 0
  local t="$1" k="$2" info host
  info="$(talosctl --talosconfig "$t" config info 2>/dev/null)" || return 0
  case "$info" in *"Endpoints:"*"not defined"*) ;; *) return 0 ;; esac
  host="$(sed -n 's#^[[:space:]]*server:[[:space:]]*https\{0,1\}://\([^:/]*\).*#\1#p' "$k" | head -n1)"
  [ -n "$host" ] || return 0
  talosctl --talosconfig "$t" config endpoint "$host" >/dev/null 2>&1 && \
    talosctl --talosconfig "$t" config node "$host" >/dev/null 2>&1 && \
    echo "kctx: set talos endpoint/node to $host"
}

_kctx_use() {
  local name="$1" f="$KCTX_DIR/$1/kubeconfig"
  if [[ ! "$name" =~ ^[a-z0-9]([a-z0-9-]*[a-z0-9])?$ ]]; then echo "kctx: bad cluster name '$name'" >&2; return 2; fi
  if [ ! -f "$f" ]; then
    echo "kctx: no local kubeconfig for '$name'; fetching from the manager..." >&2
    # pin the manager explicitly: get-kubeconfig.sh would otherwise fall back to $KUBECONFIG, i.e. the cluster picked last
    "$_KCTX_ROOT/hack/get-kubeconfig.sh" "$name" --manager-kubeconfig "${MANAGER_KUBECONFIG:-$KCTX_DIR/lab-manager/kubeconfig}" || { echo "kctx: could not fetch '$name'" >&2; return 1; }
  fi
  local t="$KCTX_DIR/$name/talosconfig"
  if [ ! -f "$t" ] && [ "$name" != lab-manager ]; then
    # best effort: not every cluster is Talos-managed, so a failure here is not an error
    "$_KCTX_ROOT/hack/get-kubeconfig.sh" "$name" --talosconfig --manager-kubeconfig "${MANAGER_KUBECONFIG:-$KCTX_DIR/lab-manager/kubeconfig}" >/dev/null 2>&1 || true
  fi
  local cur; cur="$(_kctx_current 2>/dev/null || true)"
  [ -n "$cur" ] && [ "$cur" != "$name" ] && export KCTX_PREV="$cur"
  export KUBECONFIG="$f"
  echo "kctx: using $name ($f)"
  if [ -f "$t" ]; then
    _kctx_talos_defaults "$t" "$f"
    export TALOSCONFIG="$t"
    echo "kctx: TALOSCONFIG=$t"
  else
    unset TALOSCONFIG
    echo "kctx: no talosconfig for '$name'; TALOSCONFIG unset" >&2
  fi
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

# Prune stale local cluster dirs. Known = XR files in the repo (default) or TalosClusters on the manager (--live).
_kctx_prune() {
  local live=0 known n stale=() mk="${MANAGER_KUBECONFIG:-$KCTX_DIR/lab-manager/kubeconfig}"
  case "${1:-}" in "") ;; --live) live=1 ;; *) echo "kctx: unknown -p option $1 (use --live)" >&2; return 2 ;; esac
  if [ "$live" = 1 ]; then
    command -v kubectl >/dev/null 2>&1 || { echo "kctx: kubectl not found" >&2; return 1; }
    [ -f "$mk" ] || { echo "kctx: manager kubeconfig $mk not found" >&2; return 1; }
    known="$(kubectl --kubeconfig "$mk" --request-timeout=10s get taloscluster -A -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}')" \
      || { echo "kctx: could not list TalosClusters on the manager; nothing pruned" >&2; return 1; }
  else
    known="$(for f in "$_KCTX_ROOT"/apps/talos-clusters/*.yaml; do [ -f "$f" ] && basename "$f" .yaml; done)"
  fi
  while read -r n; do
    [ -n "$n" ] && [ "$n" != lab-manager ] || continue
    printf '%s\n' "$known" | grep -qxF -- "$n" || stale+=("$n")
  done < <(_kctx_list)
  [ ${#stale[@]} -gt 0 ] || { echo "kctx: nothing to prune"; return 0; }
  printf 'kctx: no matching cluster for:\n'; printf '  %s\n' "${stale[@]}"
  local ans; read -r -p "delete these directories under $KCTX_DIR? [y/N] " ans
  case "$ans" in
    y|Y) for n in "${stale[@]}"; do
           [[ "$n" =~ ^[a-z0-9]([a-z0-9-]*[a-z0-9])?$ ]] && rm -rf -- "${KCTX_DIR:?}/$n" && echo "kctx: removed $n"
         done
         [ -n "${KCTX_PREV:-}" ] && [ ! -d "$KCTX_DIR/$KCTX_PREV" ] && unset KCTX_PREV
         return 0 ;;
    *) echo "kctx: nothing deleted" ;;
  esac
}

kctx() {
  case "${1:-}" in
    "")        _kctx_pick ;;
    -h|--help) sed -n '2,18p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//' ;;
    -l)        local c; c="$(_kctx_current 2>/dev/null || true)"; _kctx_list | while read -r n; do [ "$n" = "$c" ] && echo "* $n" || echo "  $n"; done ;;
    -c)        _kctx_current || { echo "kctx: KUBECONFIG is not set (using ~/.kube/config)" >&2; return 1; } ;;
    -p)        shift; _kctx_prune "$@" ;;
    -u)        unset KUBECONFIG TALOSCONFIG; echo "kctx: KUBECONFIG and TALOSCONFIG unset" ;;
    -)         [ -n "${KCTX_PREV:-}" ] && _kctx_use "$KCTX_PREV" || { echo "kctx: no previous cluster" >&2; return 1; } ;;
    -*)        echo "kctx: unknown option $1 (see kctx --help)" >&2; return 2 ;;
    *)         [ $# -eq 1 ] || { echo "kctx: one cluster name only" >&2; return 2; }; _kctx_use "$1" ;;
  esac
}

_kctx_complete() { COMPREPLY=( $(compgen -W "$(_kctx_list) -l -c -u -p -" -- "${COMP_WORDS[COMP_CWORD]}") ); }
complete -F _kctx_complete kctx 2>/dev/null || true

# Run directly (hack/kctx.sh ...) instead of sourced: a child process cannot set your shell's KUBECONFIG, so say so instead of silently doing nothing.
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  echo "kctx.sh must be sourced, not run:  source ${BASH_SOURCE[0]}   (then: kctx <name>)" >&2
  exit 1
fi
