# personalize-file — fill a formatted slot FILE inside an iso9660 image. Offset AND size come
# OUT of the artifact (report_lba: Startlba, Filesize), never bookkept at build time. The fill
# lands in place, in a copy, or on stdout — so a deploy can emit a secret-bearing iso without
# the filled image ever touching the build host's disk.
#   $1 = the input iso (secret-free; read-only unless it is also the in-place target)
#   $2 = output: omitted -> patch $1 in place; a path -> a filled copy; '-' -> stdout
# Prepended by the block: slot_path, manifest, and the resolver.
set -euo pipefail

artifact=${1:?usage: personalize <iso> [output|-]}
output=${2-}
required slot_path manifest

sc=0
report=$(xorriso -indev "$artifact" -find "$slot_path" -exec report_lba -- 2>/dev/null) || sc=$?
[ "$sc" = 0 ] || fatal "refusal: cannot read $artifact as an iso"
# report_lba: "File data lba:  xt , Startlba , Blocks , Filesize , path" — the extent's LBA
# and the file's byte size, both from the finished artifact.
read -r lba size < <(awk -F, \
  '/^File data lba/ { gsub(/ /, "", $2); gsub(/ /, "", $4); print $2, $4 }' <<<"$report")
[ -n "$lba" ] && [ -n "$size" ] || fatal "refusal: the artifact carries no file at $slot_path"
off=$((lba * 2048))

# The offset must land on a real filesystem — the cheap second opinion the build's formatted
# (never hollow) slot exists to answer, before a single byte is trusted to it.
mdir -i "$artifact@@$off" :: > /dev/null 2>&1 \
  || fatal "refusal: the slot at $slot_path holds no filesystem"

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

# Emit the whole iso with the slot's window substituted: the bytes before it, the filled slot,
# the bytes after. Byte-precise (iflag) so nothing rides on sector alignment.
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
