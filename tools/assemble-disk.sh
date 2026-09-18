# assemble-disk — lay this host's disk out on the TARGET and fill it, from the same pieces
# the image would have been built from. The result is the same disk an `image` delivery
# writes, with one difference that is the whole reason to do it here: the store partition
# is sized to the disk in front of us, which only the machine knows.
#
#   assemble-disk <disk> <espImage> <slotName> <slotMiB> <storeLabel> <storeUuid> \
#     <registration> <store-paths> <toplevel>
#
# The ESP arrives as a finished filesystem image — small, and byte-identical to the one the
# image endpoint carries. The store is built here: a filesystem on the partition, the
# closure copied in, the nix database loaded, and the profile links a first switch reads.
# The slot is created empty and formatted; the act fills it afterwards, exactly as it fills
# a slot the image wrote.
set -euo pipefail

disk=${1:?usage: assemble-disk <disk> <espImage> <slotName> <slotMiB> <storeLabel> <storeUuid> <registration> <store-paths> <toplevel>}
esp_image=${2:?missing esp image}
slot_name=${3:?missing slot name}
slot_mib=${4:?missing slot size}
store_label=${5:?missing store label}
store_uuid=${6:?missing store uuid}
registration=${7:?missing registration}
store_paths=${8:?missing store-paths file}
toplevel=${9:?missing toplevel}

sector=512
align=$((1024 * 1024))
mib=$((1024 * 1024))

dev=$(readlink -f "$disk")
sc=0
disk_bytes=$(blockdev --getsize64 "$dev") || sc=$?
[ "$sc" = 0 ] && [ -n "$disk_bytes" ] || fatal "cannot size $disk"
esp_bytes=$(stat -Lc %s "$esp_image")
slot_bytes=$((slot_mib * mib))

# The layout, in the image's own order: ESP, store, slot. The store takes what is left
# once the other two and the trailing GPT have their share — that is the sizing an image
# built ahead of time cannot do.
esp_start=$align
esp_end=$((esp_start + esp_bytes))
store_start=$(((esp_end + align - 1) / align * align))
slot_end=$(((disk_bytes - align) / align * align))
slot_start=$((slot_end - slot_bytes))
store_end=$((slot_start / align * align))
store_bytes=$((store_end - store_start))
[ "$store_bytes" -ge $((256 * mib)) ] \
  || fatal "$disk leaves only $((store_bytes / mib)) MiB for the store — too small to install"

info "layout on $disk: esp $((esp_bytes / mib)) MiB, store $((store_bytes / mib)) MiB," \
  "slot $slot_mib MiB"

run "partition $disk" sgdisk \
  -n "1:$((esp_start / sector)):$((esp_end / sector - 1))" -t 1:ef00 -c 1:ESP \
  -n "2:$((store_start / sector)):$((store_end / sector - 1))" -t 2:8300 -c "2:$store_label" \
  -n "3:$((slot_start / sector)):$((slot_end / sector - 1))" -t 3:8300 -c "3:$slot_name" \
  "$dev"
best_effort "reread partition tables" partprobe "$dev"
udevadm settle

# The kernel's own enumeration, never a name guessed by appending a number: nvme and loop
# devices put a `p` in front of it, and a wrong guess here writes to nothing at all.
part_of() {
  local n=$1 path
  path=$(timeout 30 lsblk -npo PATH "$dev" | tail -n +2 | sed -n "${n}p")
  [ -n "$path" ] || fatal "the kernel shows no partition $n on $dev after partitioning"
  printf '%s' "$path"
}
esp_part=$(part_of 1)
store_part=$(part_of 2)
slot_part=$(part_of 3)

# The ESP as it was built: the bootloader, the entries, the kernel and initrd. Writing the
# finished filesystem keeps it identical to what an image delivery puts there.
run "write the ESP" dd if="$esp_image" of="$esp_part" bs=4M conv=fsync status=none

run "format the store" mkfs.ext4 -q -L "$store_label" -U "$store_uuid" "$store_part"
run "format the slot" mkfs.fat -n SLOT "$slot_part"

mnt=$(mktemp -d)
add_cleanup "rmdir '$mnt' 2> /dev/null || true"
run "mount the store" mount "$store_part" "$mnt"
add_cleanup "umount '$mnt' 2> /dev/null || true"

mkdir -p "$mnt/nix/store"
count=0
while IFS= read -r p; do
  [ -n "$p" ] || continue
  cp -a "$p" "$mnt/nix/store/"
  count=$((count + 1))
done < "$store_paths"
info "copied $count store paths"

# A store is not just files: every path must be VALID in the database, or the installed
# system boots into something that cannot answer `nix-store -q` about itself.
run "load the nix db" env NIX_STATE_DIR="$mnt/nix/var/nix" NIX_STORE_DIR=/nix/store \
  nix-store --load-db < "$registration"

# The system profile as `nix-env --set` leaves it: a numbered generation plus the `system`
# link, which is what the first switch's bootloader step reads.
mkdir -p "$mnt"/nix/var/nix/profiles "$mnt"/nix/var/nix/gcroots
mkdir -p "$mnt"/etc "$mnt"/var "$mnt"/run "$mnt"/proc "$mnt"/sys "$mnt"/dev "$mnt"/tmp "$mnt"/boot
chmod 1777 "$mnt/tmp"
ln -sfn "$toplevel" "$mnt/nix/var/nix/profiles/system-1-link"
ln -sfn system-1-link "$mnt/nix/var/nix/profiles/system"
ln -sfn /nix/var/nix/profiles "$mnt/nix/var/nix/gcroots/profiles"
touch "$mnt/etc/NIXOS"

run "unmount the store" umount "$mnt"
best_effort "flush buffers" sync
info "assembled $disk"
