# The frequent pattern, proven end to end: a zfs host is REPLACED by another zfs host on
# the same disk, same pool name (the fleet convention), different machine identity — and
# the encrypted pool comes out of it. Three claims, each with its own phase:
#   - without explicit wipe intent the second install REFUSES (the found pool is
#     unencrypted, the new host expects encryption) and the first host still boots —
#     never-reformat holds even across host identities. The run rides `install.wipe=0`:
#     the form someone writes trying to turn the switch OFF must not count as intent;
#   - with `install.wipe` on the loader's command line the declared disks are cleared and
#     the create runs over the old pool's remains — labels, GUID, all of it;
#   - the disk then really holds a NEW pool, read off its labels: a different pool GUID
#     than the first install's, created by the replacement's own installer. Encryption is
#     witnessed from the pool itself at create time (dataset encryption is not a label
#     feature — an encrypted pool imports without keys);
#   - the encrypted replacement then BOOTS unattended: the install delivered the pool key
#     to the host's declared destination, and the layout's stage-1 read unlocks with it.
{ pkgs, compose, hosts }:

let
  inherit (pkgs) lib;
  a = compose hosts.zfs;
  b = compose hosts.zfs-enc;
in
{
  witnesses = [ ];
  check = pkgs.runCommand "e2e-zfs-reinstall"
  {
    nativeBuildInputs = [ pkgs.qemu pkgs.mtools pkgs.dosfstools pkgs.gptfdisk pkgs.zfs pkgs.gawk ];
    requiredSystemFeatures = [ "kvm" ];
  }
  ''
    set -euo pipefail
    prep_tree() {
      rm -rf "$1"
      mkdir "$1"
      cp "$2"/* "$1"/
      chmod -R +w "$1"
    }
    prep_tree tree-a ${a.image-kexec-install.file}
    ${lib.getExe a.image-personalize-kexec.run} "$PWD/tree-a"
    prep_tree tree-b ${b.image-kexec-install.file}
    ${lib.getExe b.image-personalize-kexec.run} "$PWD/tree-b"
    cmdline_a="$(sed -n "s/^.*--command-line='\(.*\)'$/\1/p" tree-a/kexec.sh)"
    cmdline_b="$(sed -n "s/^.*--command-line='\(.*\)'$/\1/p" tree-b/kexec.sh)"
    [ -n "$cmdline_a" ] && [ -n "$cmdline_b" ]

    truncate -s 8G target.img
    result() {
      truncate -s 16M "result-$1.img"
      mkfs.fat -n E2EOUT "result-$1.img" > /dev/null
    }
    run_qemu() {
      local tree="$1" append="$2" res="$3" log="$4"
      sc=0
      timeout 1500 qemu-system-x86_64 -enable-kvm -cpu host -m 3072 -smp 2 \
        -kernel "$tree/kernel" -initrd "$tree/initrd" -append "$append" \
        -drive if=none,id=target,format=raw,file=target.img \
        -device virtio-blk-pci,drive=target,serial=target \
        -drive if=none,id=eout,format=raw,file="result-$res.img" \
        -device virtio-blk-pci,drive=eout,serial=e2eout \
        -serial file:"$log" -display none -no-reboot || sc=$?
      echo "qemu ($log) exited $sc" >&2
      mcopy -i "result-$res.img" ::/log "result-$res" 2>/dev/null || touch "result-$res"
      echo "=== $res:" >&2; cat "result-$res" >&2
    }
    boot_target() {
      local res="$1" log="$2"
      install -m 0644 ${pkgs.OVMF.fd}/FV/OVMF_VARS.fd "vars-$res.fd"
      sc=0
      timeout 600 qemu-system-x86_64 -enable-kvm -cpu host -m 1024 -smp 2 \
        -drive if=pflash,format=raw,readonly=on,file=${pkgs.OVMF.fd}/FV/OVMF_CODE.fd \
        -drive if=pflash,format=raw,file="vars-$res.fd" \
        -drive if=none,id=target,format=raw,file=target.img \
        -device virtio-blk-pci,drive=target,serial=target \
        -drive if=none,id=eout,format=raw,file="result-$res.img" \
        -device virtio-blk-pci,drive=eout,serial=e2eout \
        -serial file:"$log" -display none -no-reboot || sc=$?
      echo "qemu ($log) exited $sc" >&2
      mcopy -i "result-$res.img" ::/log "result-$res" 2>/dev/null || touch "result-$res"
      echo "=== $res:" >&2; cat "result-$res" >&2
    }

    # The head of the zfs partition holds labels L0+L1 — enough to read the pool identity.
    # zdb -l exits nonzero over the missing tail labels (L2/L3 live at the partition's
    # end), so its exit is captured and the assertions run on what it printed.
    pool_label() {
      part_num="$(sgdisk -p target.img | awk '$NF == "zfs" { print $1 }')"
      [ -n "$part_num" ]
      part_start="$(sgdisk -i "$part_num" target.img | awk '/^First sector/ { print $3 }')"
      [ -n "$part_start" ]
      dd if=target.img of="$1" bs=512 skip="$part_start" count=8192 status=none
      sc=0
      zdb -l "$1" > "$1.txt" || sc=$?
      echo "zdb -l $1 exited $sc" >&2
    }
    echo "== phase 1: the first zfs host installs and boots =="
    result a
    run_qemu tree-a "$cmdline_a" a install-a.log
    grep -q "INSTALL-OK e2e-zfs" result-a
    pool_label label-a
    guid_a="$(awk '/pool_guid:/ { print $2; exit }' label-a.txt)"
    [ -n "$guid_a" ]
    grep -q "hostname: 'e2e-zfs-installer'" label-a.txt
    result a-boot
    boot_target a-boot boot-a.log
    grep -q "E2E-BOOT-OK e2e-zfs" result-a-boot

    echo "== phase 2: the replacement WITHOUT wipe intent must refuse, the old host survives =="
    result b-refused
    run_qemu tree-b "$cmdline_b install.wipe=0" b-refused refuse-b.log
    grep -q "INSTALL-FAILED e2e-zfs-enc" result-b-refused
    ! grep -q "REINSTALL" result-b-refused
    ! grep -q "INSTALL-OK" result-b-refused
    result a-again
    boot_target a-again boot-a-again.log
    grep -q "E2E-BOOT-OK e2e-zfs" result-a-again

    echo "== phase 3: with install.wipe the replacement clears the old pool and installs =="
    result b
    run_qemu tree-b "$cmdline_b install.wipe" b install-b.log
    grep -q "REINSTALL e2e-zfs-enc" result-b
    grep -q "E2E-POOL-ENCRYPTION aes-256-gcm" result-b
    grep -q "INSTALL-OK e2e-zfs-enc" result-b

    echo "== phase 4: the disk holds a NEW pool — fresh GUID, made by the replacement =="
    pool_label label-b
    guid_b="$(awk '/pool_guid:/ { print $2; exit }' label-b.txt)"
    [ -n "$guid_b" ]
    [ "$guid_a" != "$guid_b" ]
    grep -q "hostname: 'e2e-zfs-enc-installer'" label-b.txt

    echo "== phase 5: the encrypted replacement boots unattended — the delivered key unlocks =="
    result b-boot
    boot_target b-boot boot-b.log
    grep -q "E2E-BOOT-OK e2e-zfs-enc" result-b-boot

    touch "$out"
  ''
  ;
}
