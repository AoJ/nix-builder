# sidecar-json — one object, target path -> base64 content, at RUNTIME. Base64 because a
# secret is bytes, and json only carries text.
#   $1 = where the sidecar lands
# Prepended by the block: manifest, and the resolver.
set -euo pipefail

out=${1:?usage: sidecar <out>}
required manifest

# Nothing may touch $out before every file resolves: a refusal that leaves an empty file
# behind is a refusal that wrote something.
staged=$(mktemp -d)
add_cleanup rm -rf "$staged"
stage_manifest "$manifest" "$staged"

sc=0
json=$(
  set -euo pipefail
  {
    while IFS= read -r target; do
      jq -n --arg t "$target" --arg c "$(base64 -w0 < "$staged$target")" \
        '{ key: $t, value: $c }'
    done < <(manifest_targets "$manifest")
  } | jq -s -S from_entries
) || sc=$?
[ "$sc" = 0 ] || fatal "sidecar json assembly failed (exit $sc)"
printf '%s\n' "$json" > "$out"
info "sidecar written: $out"
