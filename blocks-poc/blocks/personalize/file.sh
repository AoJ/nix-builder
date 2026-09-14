# personalize-file — fill a formatted slot FILE inside a finished iso9660 image. The offset
# is read OUT of the artifact (report_lba), never bookkept at build time.
#   $1 = the artifact (an iso)
# Prepended by the block: slot_path, manifest (`<source>\t<target>` lines).
set -euo pipefail

artifact=${1:?usage: personalize <artifact>}
required slot_path manifest

sc=0
lba=$(xorriso -indev "$artifact" -find "$slot_path" -exec report_lba -- 2>/dev/null \
  | awk -F, '/^File data lba/ { gsub(/ /, "", $2); print $2 }') || sc=$?
[ "$sc" = 0 ] && [ -n "$lba" ] || fatal "refusal: the artifact carries no file at $slot_path"
off=$((lba * 2048))

mdir -i "$artifact@@$off" :: > /dev/null 2>&1 \
  || fatal "refusal: the file at $slot_path holds no filesystem"

while IFS=$'\t' read -r src dest; do
  [ -n "$src" ] || continue
  [ -e "$src" ] || fatal "refusal: no such file to place: $src"
done < "$manifest"

readback=$(mktemp)
add_cleanup rm -f "$readback"
while IFS=$'\t' read -r src dest; do
  [ -n "$src" ] || continue
  run "place $dest" mcopy -o -i "$artifact@@$off" "$src" "::$dest"
  run "read back $dest" mcopy -o -i "$artifact@@$off" "::$dest" "$readback"
  run "verify $dest" cmp "$readback" "$src"
done < "$manifest"
info "personalized $artifact"
