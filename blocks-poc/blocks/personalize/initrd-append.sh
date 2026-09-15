# personalize-initrd — append the slot's files to a netboot payload's initrd as one more
# cpio segment. The artifact must be the CALLER's writable copy — a store path is not one.
#   $1 = the artifact (a netboot tree holding ./initrd)
# Prepended by the block: slot_name, manifest (`<source>\t<target>` lines).
set -euo pipefail

artifact=${1:?usage: personalize <artifact>}
required slot_name manifest

[ -w "$artifact/initrd" ] || fatal "refusal: no writable initrd at $artifact"

# The build RESERVED the slot as a marker segment. Listing cannot find it — cpio stops at
# the FIRST segment's trailer — but a newc header carries the member name as plain bytes,
# so the bytes are the check.
grep -aqF -- ".slot-$slot_name" "$artifact/initrd" \
  || fatal "refusal: the artifact carries no slot segment named $slot_name"

while IFS=$'\t' read -r src dest; do
  [ -n "$src" ] || continue
  [ -e "$src" ] || fatal "refusal: no such file to place: $src"
done < "$manifest"

staged=$(mktemp -d)
add_cleanup rm -rf "$staged"
while IFS=$'\t' read -r src dest; do
  [ -n "$src" ] || continue
  mkdir -p "$staged$(dirname "$dest")"
  cp "$src" "$staged$dest"
done < "$manifest"

before=$(stat -c%s "$artifact/initrd")
# The subshell restates the modes it needs: inherited options are one refactor away from
# not being there, and a cpio that fails mid-pipeline must never leave a half-appended
# initrd looking done.
sc=0
(
  set -euo pipefail
  cd "$staged"
  find . -mindepth 1 | sort | cpio -o -H newc -R +0:+0 --reproducible --quiet
) >> "$artifact/initrd" || sc=$?
if [ "$sc" != 0 ]; then
  truncate -s "$before" "$artifact/initrd"
  fatal "cpio append failed (exit $sc); the artifact was restored to its prior size"
fi

# cpio -t strips the leading "./" a find-fed archive stores, so the anchor is the bare
# relative path.
while IFS=$'\t' read -r src dest; do
  [ -n "$src" ] || continue
  tail -c +$((before + 1)) "$artifact/initrd" | cpio -t --quiet \
    | grep -qxF "${dest#/}" \
    || fatal "the appended segment does not list $dest"
done < "$manifest"
info "personalized $artifact"
