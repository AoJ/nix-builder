# sidecar-vfat — build the vfat sidecar at RUNTIME, at the path given.
#   $1 = where the sidecar lands
# Prepended by the block: fat_image, label, volume_id, size_bytes, manifest, and the
# resolver.
set -euo pipefail

out=${1:?usage: sidecar <out>}
required fat_image label volume_id size_bytes manifest

staged=$(mktemp -d)
add_cleanup rm -rf "$staged"
stage_manifest "$manifest" "$staged"

# fat-image takes its own <source>\t<target> manifest; the staged tree is what it copies.
fat_manifest=$(mktemp)
add_cleanup rm -f "$fat_manifest"
while IFS= read -r target; do
  printf '%s\t%s\n' "$staged$target" "$target" >> "$fat_manifest"
done < <(manifest_targets "$manifest")

"$fat_image" "$out" "$label" "$volume_id" "$size_bytes" "$fat_manifest" auto
info "sidecar written: $out"
