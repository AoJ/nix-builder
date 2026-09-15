# store-cpio — the netboot shape: a store as a cpio archive to be APPENDED to an initrd. The
# paths land on the initramfs tmpfs (writable), but the database still boots empty — so the
# archive carries the dump at the same constant path, and the same kind of unit loads it.
#
#   store-cpio <out> <registration> <store-paths>
set -euo pipefail

out=${1:?usage: store-cpio <out> <registration> <store-paths>}
registration=${2:?missing registration}
store_paths=${3:?missing store-paths file}

staged=$(mktemp -d)
add_cleanup rm -rf "$staged"
mkdir -p "$staged/nix/store"
while IFS= read -r p; do
  [ -n "$p" ] || continue
  cp -a --reflink=auto "$p" "$staged/nix/store/"
done < "$store_paths"
cp "$registration" "$staged/nix/store/nix-path-registration"

# Canonical times, forced ownership, renumbered inodes, ignored device numbers: every one of
# these is a wall-clock or builder-local value that would otherwise leak into the bytes.
find "$staged" -exec touch -h -d @1 {} +
sc=0
(
  set -euo pipefail
  cd "$staged"
  find . -mindepth 1 | sort | cpio -o -H newc -R +0:+0 --reproducible --quiet
) > "$out" || sc=$?
[ "$sc" = 0 ] || fatal "store cpio failed (exit $sc)"
