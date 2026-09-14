# personalize-initrd — append the slot's files to a netboot payload's initrd as one more
# cpio segment; the initramfs takes concatenated segments as they come, so the slot is the
# append point itself and the only artifact check left is the read-back.
#   $1 = the artifact (a netboot tree holding ./initrd)
# Prepended by the block: manifest (`<source>\t<target>` lines).
set -euo pipefail

artifact=${1:?usage: personalize <artifact>}
required manifest

[ -w "$artifact/initrd" ] || fatal "refusal: no writable initrd at $artifact"

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
(cd "$staged" && find . -mindepth 1 | sort \
  | cpio -o -H newc -R +0:+0 --reproducible --quiet) >> "$artifact/initrd"

while IFS=$'\t' read -r src dest; do
  [ -n "$src" ] || continue
  tail -c +$((before + 1)) "$artifact/initrd" | cpio -t --quiet | grep -qF "${dest#/}" \
    || fatal "the appended segment does not list $dest"
done < "$manifest"
info "personalized $artifact"
