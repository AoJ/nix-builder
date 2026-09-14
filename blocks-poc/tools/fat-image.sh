# fat-image — build a FAT filesystem image from a manifest of files. No mount, no loop
# device, no root: mtools writes into the image at its own offsets. None of these tools look
# at the payload's ELF machine type, which is why an aarch64 ESP assembles on an x86 runner
# at native speed (nixpkgs does the same at iso-image.nix's buildPackages.mtools).
#
#   fat-image <out> <label> <volume-id> <slack-bytes> <manifest> <fat>
#
# manifest: one `<source-path>\t<absolute-path>` line per file; may be EMPTY — that is a
# slot, reserved and formatted with nothing in it. Parent directories are derived from the
# paths — a caller states files, not the tree.
# fat: `32` forces FAT32 (an ESP); `auto` lets mkfs.fat pick, which is what a small slot
# needs — FAT32 is not legal under ~33 MiB.
#
# Determinism: mkfs.fat honours SOURCE_DATE_EPOCH (measured: without it two runs seconds
# apart differ), and the volume id is passed in rather than generated, because nixpkgs' own
# ESPs all share id 1234-5678 and label EFIBOOT — which is how a by-label lookup picks the
# wrong disk.
set -euo pipefail

out=${1:?usage: fat-image <out> <label> <volume-id> <slack-bytes> <manifest> <fat>}
label=${2:?missing label}
volume_id=${3:?missing volume id}
slack=${4:?missing slack bytes}
manifest=${5:?missing manifest}
fat=${6:?missing fat type (32|auto)}

[ -f "$manifest" ] || fatal "fat-image: no such manifest: $manifest"

mib=$((1024 * 1024))

data=0
dirs=()
while IFS=$'\t' read -r src dest; do
  [ -n "$src" ] || continue
  [ -e "$src" ] || fatal "fat-image: manifest source does not exist: $src"
  sz=$(stat -Lc %s "$src")
  data=$((data + sz))
  d=$(dirname "$dest")
  while [ "$d" != "/" ] && [ "$d" != "." ]; do
    dirs+=("$d")
    d=$(dirname "$d")
  done
done < "$manifest"

# The slack is a floor and not a courtesy: FAT32 needs enough clusters to be legal at all,
# and an empty slot IS its slack.
bytes=$(((data + slack + mib - 1) / mib * mib))
info "fat: $((bytes / mib)) MiB ($((data / 1024)) KiB of payload), label=$label id=$volume_id"

fat_args=()
[ "$fat" = auto ] || fat_args+=(-F "$fat")
truncate -s "$bytes" "$out"
run "mkfs.fat" env SOURCE_DATE_EPOCH=0 mkfs.fat "${fat_args[@]}" -n "$label" -i "$volume_id" "$out"

# Parents before children: a prefix always sorts before the longer path, so a plain sort -u
# yields a creation order mmd can follow (it does not create parents itself).
#
# The guard is not defensive noise: a manifest whose every target sits at the ROOT leaves
# this list empty, and `printf '%s\n'` with no arguments still applies its format once, so
# the loop would call `mmd ::` and mtools would refuse it as "an entry named . or ..".
if [ ${#dirs[@]} -gt 0 ]; then
  mapfile -t ordered < <(printf '%s\n' "${dirs[@]}" | sort -u)
  for d in "${ordered[@]}"; do
    run "mmd $d" mmd -i "$out" "::$d"
  done
fi

while IFS=$'\t' read -r src dest; do
  [ -n "$src" ] || continue
  run "mcopy $dest" mcopy -o -i "$out" "$src" "::$dest"
done < "$manifest"
