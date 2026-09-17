# sidecar-vfat — build the vfat sidecar at RUNTIME, at the path given.
#   $1 = where the sidecar lands
# Prepended by the block: fat_image, label, volume_id, size_bytes, manifest.
set -euo pipefail

out=${1:?usage: sidecar <out>}
required fat_image label volume_id size_bytes manifest

"$fat_image" "$out" "$label" "$volume_id" "$size_bytes" "$manifest" auto
info "sidecar written: $out"
