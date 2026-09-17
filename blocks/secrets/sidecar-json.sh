# sidecar-json — one object, target path -> base64 content, at RUNTIME. Base64 because a
# secret is bytes, and json only carries text.
#   $1 = where the sidecar lands
# Prepended by the block: manifest.
set -euo pipefail

out=${1:?usage: sidecar <out>}
required manifest

# Nothing may touch $out before every check has passed: a refusal that leaves an empty
# file behind is a refusal that wrote something.
while IFS=$'\t' read -r src dest; do
  [ -n "$src" ] || continue
  [ -e "$src" ] || fatal "no such file: $src"
done < "$manifest"

sc=0
json=$(
  set -euo pipefail
  {
    while IFS=$'\t' read -r src dest; do
      [ -n "$src" ] || continue
      jq -n --arg t "$dest" --arg c "$(base64 -w0 < "$src")" '{ key: $t, value: $c }'
    done < "$manifest"
  } | jq -s -S from_entries
) || sc=$?
[ "$sc" = 0 ] || fatal "sidecar json assembly failed (exit $sc)"
printf '%s\n' "$json" > "$out"
info "sidecar written: $out"
