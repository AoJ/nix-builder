# personalize-partition — fill a formatted slot PARTITION in a finished disk image.
#   $1 = the artifact (a raw disk image)
# Prepended by the block: slot_name, manifest, and the resolver.
#
# Every check runs before the first write: a secret written to the wrong offset is not
# recoverable by noticing afterwards, so a refusal must leave the artifact untouched.
set -euo pipefail

artifact=${1:?usage: personalize <artifact>}
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
[ -n "$start" ] || fatal "refusal: cannot locate partition $num"
off=$((start * 512))

# A cheap second opinion on the offset arithmetic — the reason the image build leaves the
# slot FORMATTED: a hole answers no question about whether the offset is right.
mdir -i "$artifact@@$off" :: > /dev/null 2>&1 \
  || fatal "refusal: the slot at sector $start holds no filesystem"

staged=$(mktemp -d)
add_cleanup "rm -rf $(printf '%q' "$staged")"
stage_manifest "$manifest" "$staged"

while IFS= read -r target; do
  run "place $target" mcopy -o -i "$artifact@@$off" "$staged$target" "::$target"
  mcopy -i "$artifact@@$off" "::$target" - | cmp - "$staged$target" \
    || fatal "read-back mismatch: $target"
done < <(manifest_targets "$manifest")
info "personalized $artifact"
