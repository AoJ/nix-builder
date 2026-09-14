# The install act, shape only: the real steps arrive with the move into blocks/. What is
# already real is the CONTRACT — every host-specific value arrives as an injected variable,
# never as knowledge of this script's own.
#   Prepended by the block: prepare, mount_cmd, toplevel, key_destination.
set -euo pipefail

required prepare mount_cmd toplevel key_destination

run "prepare storage" "$prepare"
run "mount target" "$mount_cmd" /mnt
run "copy closure" nix copy --no-check-sigs --to /mnt "$toplevel"
run "place key" install -D -m 0400 /run/install/key "/mnt$key_destination"
run "make bootable" nixos-enter --root /mnt -- "$toplevel/bin/switch-to-configuration" boot
info "installed $toplevel"
