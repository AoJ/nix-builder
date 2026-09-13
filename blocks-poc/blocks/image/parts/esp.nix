{ pkgs, lib, ids }:

{ name, system, bootloader, entries }:

let
  efiFileName = {
    "x86_64-linux" = "BOOTX64.EFI";
    "aarch64-linux" = "BOOTAA64.EFI";
  }.${system};
in
pkgs.runCommand "esp.img"
  {
    nativeBuildInputs = [
      pkgs.dosfstools pkgs.mtools pkgs.coreutils pkgs.findutils pkgs.gawk
    ];
  }
  ''
    set -euo pipefail
    staged="$(mktemp -d)"
    mkdir -p "$staged/EFI/BOOT" "$staged/loader/entries"
    cp ${bootloader} "$staged/EFI/BOOT/${efiFileName}"
    printf 'timeout 1\ndefault nixos\n' > "$staged/loader/loader.conf"
    ${lib.concatMapStringsSep "\n" (e: ''
      cp ${e.kernel} "$staged/${e.name}-kernel"
      cp ${e.initrd} "$staged/${e.name}-initrd"
      {
        printf 'title %s\n' ${lib.escapeShellArg e.title}
        printf 'linux /%s-kernel\n' ${lib.escapeShellArg e.name}
        printf 'initrd /%s-initrd\n' ${lib.escapeShellArg e.name}
        printf 'options %s\n' ${lib.escapeShellArg (lib.concatStringsSep " " e.kernelParams)}
      } > "$staged/loader/entries/${e.name}.conf"
    '') entries}

    # Size from the FILES, not from `du`: du reports ALLOCATED blocks, which depend on the
    # builder's own filesystem, so two builders can size one tree differently. A directory
    # costs a cluster of its own.
    clusters="$( { find "$staged" -type f -printf '%s\n'
                   find "$staged" -type d -printf '4096\n'
                 } | awk '{ n += int(($1 + 4095) / 4096) } END { print n + 0 }')"
    size_mib=$(( (clusters * 4 + 1023) / 1024 + 4 ))
    [ "$size_mib" -ge 36 ] || size_mib=36

    truncate -s "''${size_mib}M" "$out"
    # mkfs.fat and mtools both honour the stdenv's SOURCE_DATE_EPOCH, which is where every
    # timestamp in this image comes from; without it mkfs.fat reads the wall clock. The volume
    # id comes from the image name, so two images never answer the same by-uuid lookup.
    mkfs.fat -F 32 -n ESP -i ${ids.volumeId "${name}:esp"} "$out"
    (cd "$staged" && find . -mindepth 1 -type d -printf '%P\n' | sort \
      | while IFS= read -r d; do mmd -i "$out" "::/$d"; done)
    (cd "$staged" && find . -mindepth 1 -type f -printf '%P\n' | sort \
      | while IFS= read -r f; do mcopy -i "$out" "$f" "::/$f"; done)
  ''
