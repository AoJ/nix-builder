# sidecar-iso — build the iso9660 sidecar at RUNTIME, at the path given.
#   $1 = where the sidecar lands
# Prepended by the block: volume_id, manifest.
set -euo pipefail

out=${1:?usage: sidecar <out>}
required volume_id manifest

staged=$(mktemp -d)
add_cleanup rm -rf "$staged"
while IFS=$'\t' read -r src dest; do
  [ -n "$src" ] || continue
  [ -e "$src" ] || fatal "no such file: $src"
  mkdir -p "$staged$(dirname "$dest")"
  cp "$src" "$staged$dest"
done < "$manifest"

# No stdenv at runtime: the epoch is set here, and the staged copies carry cp's wall
# clock, so their times are canonicalized too. The volume id is passed in, never generated.
find "$staged" -exec touch -h -d @0 {} +
run "xorriso" env SOURCE_DATE_EPOCH=0 xorriso -as mkisofs -r -J \
  -volid "$volume_id" -o "$out" "$staged"
info "sidecar written: $out"
