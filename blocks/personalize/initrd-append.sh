# personalize-initrd — append the slot's files to a netboot initrd as one more cpio segment.
# The new initrd lands in place, in a copy, or on stdout — so a deploy can emit it without the
# personalized initrd touching the build host's disk. The kernel beside it is never changed;
# a stream carries only the initrd, to be paired with that untouched kernel.
#   $1 = the artifact (a netboot tree holding ./initrd; ./initrd read-only unless in-place)
#   $2 = output: omitted -> append to $1/initrd in place; a path -> the new initrd; '-' -> stdout
# Prepended by the block: slot_name, manifest, and the resolver.
set -euo pipefail

artifact=${1:?usage: personalize <tree> [output|-]}
output=${2-}
required slot_name manifest

initrd="$artifact/initrd"
[ -r "$initrd" ] || fatal "refusal: no readable initrd at $artifact"
[ -n "$output" ] || [ -w "$initrd" ] || fatal "refusal: in-place needs a writable initrd at $artifact"

# The build RESERVED the slot as a marker segment. Listing cannot find it — cpio stops at
# the FIRST segment's trailer — but a newc header carries the member name as plain bytes,
# so the bytes are the check.
grep -aqF -- ".slot-$slot_name" "$initrd" \
  || fatal "refusal: the artifact carries no slot segment named $slot_name"

staged=$(mktemp -d)
add_cleanup "rm -rf $(printf '%q' "$staged")"
stage_manifest "$manifest" "$staged/files"

# Build the segment ONCE and verify it lists every target BEFORE placing it — so no output
# mode can emit a half-built segment, and the in-place append is bytes that already checked out.
# The subshell restates the modes it needs: inherited options are one refactor away from not
# being there, and the staged modes ride along, since a cpio segment can carry them.
seg="$staged/segment.cpio"
(
  set -euo pipefail
  cd "$staged/files"
  find . -mindepth 1 | sort | cpio -o -H newc -R +0:+0 --reproducible --quiet
) > "$seg"
while IFS= read -r target; do
  cpio -t --quiet < "$seg" | grep -qxF "${target#/}" \
    || fatal "the built segment does not list $target"
done < <(manifest_targets "$manifest")

# A new segment must start 4-byte aligned or the kernel's parser stops at a misaligned magic;
# the zero padding between archives is what the format skips.
pre=$(stat -c%s "$initrd")
pad=$(( (4 - pre % 4) % 4 ))

emit_tail() {
  [ "$pad" = 0 ] || head -c "$pad" /dev/zero
  dd if="$seg" bs=1M status=none
}

case "$output" in
  "")  sc=0
       emit_tail >> "$initrd" || sc=$?
       [ "$sc" = 0 ] || { truncate -s "$pre" "$initrd"; fatal "append failed (exit $sc); initrd restored"; }
       info "personalized $initrd in place" ;;
  "-") dd if="$initrd" bs=1M status=none; emit_tail; info "streamed personalized initrd" ;;
  *)   { dd if="$initrd" bs=1M status=none; emit_tail; } > "$output"; info "wrote personalized initrd to $output" ;;
esac
