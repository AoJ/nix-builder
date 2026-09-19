# personalize-file — fill a formatted slot FILE inside a finished iso9660 image. The offset
# is read OUT of the artifact (report_lba), never bookkept at build time.
#   $1 = the artifact (an iso)
# Prepended by the block: slot_path, manifest, and the resolver.
set -euo pipefail

artifact=${1:?usage: personalize <artifact>}
required slot_path manifest

sc=0
report=$(xorriso -indev "$artifact" -find "$slot_path" -exec report_lba -- 2>/dev/null) || sc=$?
[ "$sc" = 0 ] || fatal "refusal: cannot read $artifact as an iso"
lba=$(awk -F, '/^File data lba/ { gsub(/ /, "", $2); print $2 }' <<<"$report")
[ -n "$lba" ] || fatal "refusal: the artifact carries no file at $slot_path"
off=$((lba * 2048))

mdir -i "$artifact@@$off" :: > /dev/null 2>&1 \
  || fatal "refusal: the file at $slot_path holds no filesystem"

staged=$(mktemp -d)
add_cleanup "rm -rf $(printf '%q' "$staged")"
stage_manifest "$manifest" "$staged"

while IFS= read -r target; do
  run "place $target" mcopy -o -i "$artifact@@$off" "$staged$target" "::$target"
  mcopy -i "$artifact@@$off" "::$target" - | cmp - "$staged$target" \
    || fatal "read-back mismatch: $target"
done < <(manifest_targets "$manifest")
info "personalized $artifact"
