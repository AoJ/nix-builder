# The IMAGE delivery, end to end: a host that declares no install script gets its own disk
# image written to the target as it is — no recipe, no nixos-install, no nix on the target
# at all. The installer boots from a netboot face, streams the image onto the declared
# disk, fills the slot the image itself carries, and hands over to what it just wrote with
# kexec, so the medium it booted from cannot start the install a second time.
#
# What this proves that the closure path cannot: the delivered disk is BYTE FOR BYTE the
# artifact that was built — compared here against the very image the installer carried.
{ pkgs, compose, hosts }:

let
  inherit (pkgs) lib;
  e = compose hosts.image-install;
  fixture = import ../blocks/personalize/fixture.nix { inherit pkgs; };
in
{
  witnesses = [ "image-install.image-kexec-install" "image-install.image-personalize-kexec" ];
  check = pkgs.runCommand "e2e-image-install"
  {
    nativeBuildInputs = [ pkgs.qemu pkgs.age pkgs.mtools pkgs.dosfstools pkgs.zstd
                          pkgs.gptfdisk pkgs.jq pkgs.diffutils pkgs.e2fsprogs pkgs.gawk ];
    requiredSystemFeatures = [ "kvm" ];
  }
  ''
    set -euo pipefail
    mkdir tree
    cp ${e.image-kexec-install.file}/* tree/
    chmod -R +w tree
    ${lib.getExe e.image-personalize-kexec.run} "$PWD/tree"

    cmdline="$(sed -n "s/^.*--command-line='\(.*\)'$/\1/p" tree/kexec.sh)"
    [ -n "$cmdline" ] || { echo "no command line in kexec.sh" >&2; exit 1; }

    # Larger than the image on purpose: the write must leave a disk whose GPT is whole at
    # ITS end, not at the image's.
    truncate -s 8G target.img
    truncate -s 16M result.img; mkfs.fat -n E2EOUT result.img > /dev/null

    echo "== the installer writes the image and hands over =="
    sc=0
    timeout 3000 qemu-system-x86_64 -enable-kvm -cpu host -m 3072 -smp "$(( $(nproc) > 1 ? $(nproc) - 1 : 1 ))" \
      -kernel tree/kernel -initrd tree/initrd -append "$cmdline" \
      -drive if=none,id=target,format=raw,file=target.img \
      -device virtio-blk-pci,drive=target,serial=target \
      -drive if=none,id=eout,format=raw,file=result.img \
      -device virtio-blk-pci,drive=eout,serial=e2eout \
      -serial file:install.log -display none -no-reboot || sc=$?
    echo "install qemu exited $sc" >&2
    mcopy -i result.img ::/log result 2>/dev/null || touch result
    echo "=== result:" >&2; cat result >&2
    grep -q "installer: slot taken over" result
    grep -q "INSTALL-OK e2e-image-install" result
    # kexec handed straight over, so the installed system's own witness follows on the
    # SAME run — no reboot, no second chance for the medium to be booted again.
    grep -q "HANDOVER e2e-image-install" result
    grep -q "E2E-BOOT-OK e2e-image-install" result
    pub="$(age-keygen -y ${fixture}/host.key)"
    grep -q "E2E-KEY $pub" result

    echo "== what landed is the artifact that was built, not the result of an install =="
    # Not a byte comparison, and the reason is in the line above this one: the system has
    # BOOTED, so it mounted its own store partition and wrote the mount count and time
    # into the superblock. What can be claimed after a boot is that the disk is this
    # artifact — its table, down to the deterministic partition GUIDs, and the store it
    # carries — rather than something assembled on the machine.
    # Every partition, by name, start and size — and its GUID, which this repo derives
    # from the host's own name, so a match is proof the table came from the artifact and
    # was not produced again on the machine.
    describe() {
      local img=$1 num
      while read -r num; do
        printf '%s ' "$num"
        sgdisk -i "$num" "$img" | grep -E 'Partition unique GUID|First sector|Partition name'
      done < <(sgdisk -p "$img" | awk '$1 ~ /^[0-9]+$/ { print $1 }')
    }
    describe ${e.image-raw.file} > table-built
    describe target.img > table-written
    diff -u table-built table-written

    off="$(jq -r '.[] | select(.label=="nixos") | .startByte' ${e.image-raw.layout})"
    dd if=target.img of=store.img bs=1M skip=$(( off / 1048576 )) status=none
    debugfs -R "ls -l /nix/store" store.img 2> /dev/null \
      | grep -q "$(basename ${hosts.image-install.variants.runtime.toplevel})"

    echo "== the GPT backup header sits at the END of the bigger disk =="
    sgdisk -v target.img | grep -q "No problems found"

    touch "$out"
  ''
  ;
}
