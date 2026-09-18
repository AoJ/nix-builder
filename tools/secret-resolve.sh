# Prepended into every runner that consumes a secret manifest. It resolves one line's
# bytes into a staged file and knows nothing about what those bytes are.
#
# Staging is deliberate: every check runs before the first write to an artifact, and a
# read-back needs the bytes a second time. The staging directory is the runner's own
# temporary state, removed by its EXIT trap — nothing is left behind and nothing plaintext
# ever reaches the store.

# stage_manifest <manifest> <staging dir> — lays every declared target out under the
# staging root, with its declared mode.
stage_manifest() {
  local manifest=$1 root=$2
  local kind spec target mode dest
  while IFS=$'\t' read -r kind spec target mode; do
    [ -n "$kind" ] || continue
    dest="$root$target"
    mkdir -p "$(dirname "$dest")"
    case "$kind" in
      text | file)
        [ -e "$spec" ] || fatal "refusal: no such file to place: $spec"
        cp "$spec" "$dest"
        ;;
      env)
        # Unset is a refusal, empty is not: a caller may legitimately place an empty file,
        # but a name that was never exported is a mistake the runner must not paper over.
        [ -n "${!spec+set}" ] || fatal "refusal: the environment carries no $spec"
        printf '%s' "${!spec}" > "$dest"
        ;;
      *)
        fatal "refusal: unknown content kind '$kind' for $target"
        ;;
    esac
    chmod "$mode" "$dest"
  done < "$manifest"
}

# manifest_targets <manifest> — the declared target paths, one per line.
manifest_targets() {
  local kind spec target mode
  while IFS=$'\t' read -r kind spec target mode; do
    [ -n "$kind" ] || continue
    printf '%s\n' "$target"
  done < "$1"
}
