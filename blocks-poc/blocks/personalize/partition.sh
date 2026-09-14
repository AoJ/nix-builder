# personalize-partition — fill a formatted slot PARTITION in a finished disk image.
#   $1 = the artifact (a raw disk image)
# Prepended by the block: slot_name, manifest (`<source>\t<target>` lines).
#
# Every check runs before the first write: a private key written to the wrong offset is not
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
start=$(sgdisk -i "$num" "$artifact" | awk '/^First sector/ { print $3 }') || sc=$?
[ "$sc" = 0 ] && [ -n "$start" ] || fatal "refusal: cannot locate partition $num"
off=$((start * 512))

# A cheap second opinion on the offset arithmetic — the reason the image build leaves the
# slot FORMATTED: a hole answers no question about whether the offset is right.
mdir -i "$artifact@@$off" :: > /dev/null 2>&1 \
  || fatal "refusal: the slot at sector $start holds no filesystem"

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
