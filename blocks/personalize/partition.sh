# personalize-partition — fill a formatted slot PARTITION in a disk image. Offset AND size come
# OUT of the partition table (sgdisk), never bookkept at build time. The fill lands in place, in
# a copy, or on stdout — so a deploy can emit a secret-bearing image without the filled image
# ever touching the build host's disk.
#   $1 = the input image (secret-free; read-only unless it is also the in-place target)
#   $2 = output: omitted -> patch $1 in place; a path -> a filled copy; '-' -> stdout
# Prepended by the block: slot_name, manifest, and the resolver.
#
# Every check runs before the first write: a secret written to the wrong offset is not
# recoverable by noticing afterwards, so a refusal must leave the artifact untouched.
set -euo pipefail

artifact=${1:?usage: personalize <image> [output|-]}
output=${2-}
required slot_name manifest

sc=0
table=$(sgdisk -p "$artifact" 2>/dev/null) || sc=$?
[ "$sc" = 0 ] || fatal "refusal: cannot read a partition table off $artifact"
num=$(awk -v n="$slot_name" '$NF == n { print $1 }' <<<"$table")
[ -n "$num" ] || fatal "refusal: the artifact carries no partition named $slot_name"

sc=0
part_info=$(sgdisk -i "$num" "$artifact") || sc=$?
[ "$sc" = 0 ] || fatal "refusal: cannot read partition $num off $artifact"
start=$(awk '/^First sector/ { print $3 }' <<<"$part_info")
last=$(awk '/^Last sector/ { print $3 }' <<<"$part_info")
[ -n "$start" ] && [ -n "$last" ] || fatal "refusal: cannot locate partition $num"
off=$((start * 512))
size=$(( (last - start + 1) * 512 ))

# A cheap second opinion on the offset arithmetic — the reason the image build leaves the
# slot FORMATTED: a hole answers no question about whether the offset is right.
mdir -i "$artifact@@$off" :: > /dev/null 2>&1 \
  || fatal "refusal: the slot at sector $start holds no filesystem"

# Build the FILLED slot in a temp dir sized to the SLOT, never the image: the formatted slot
# copied out keeps the build's FAT geometry exactly, the secrets drop in, each is read back.
staged=$(mktemp -d)
add_cleanup "rm -rf $(printf '%q' "$staged")"
slot="$staged/slot.img"
run "read slot" dd if="$artifact" of="$slot" bs=1M \
  skip="$off" count="$size" iflag=skip_bytes,count_bytes status=none

stage_manifest "$manifest" "$staged/files"
while IFS= read -r target; do
  run "place $target" mcopy -o -i "$slot" "$staged/files$target" "::$target"
  mcopy -i "$slot" "::$target" - | cmp - "$staged/files$target" \
    || fatal "read-back mismatch: $target"
done < <(manifest_targets "$manifest")

# Emit the whole image with the slot partition's window substituted: the bytes before it, the
# filled slot, the bytes after (other partitions and the backup GPT ride through untouched).
place() {
  dd if="$artifact" bs=1M count="$off" iflag=count_bytes status=none
  dd if="$slot" bs=1M status=none
  dd if="$artifact" bs=1M skip=$((off + size)) iflag=skip_bytes status=none
}

case "$output" in
  "")  run "patch" dd if="$slot" of="$artifact" bs=1M \
         seek="$off" oflag=seek_bytes conv=notrunc status=none
       info "personalized $artifact in place" ;;
  "-") place; info "streamed personalized $artifact" ;;
  *)   place > "$output"; info "wrote personalized copy to $output" ;;
esac
