{ pkgs, lib, ids }:

{ name, partitions }:

let
  typeCode = { vfat = "ef00"; ext4 = "8300"; };
  quoted = f: lib.concatMapStringsSep " " (p: lib.escapeShellArg (f p)) partitions;
in
pkgs.runCommand "${name}.img"
  {
    nativeBuildInputs = [ pkgs.gptfdisk pkgs.coreutils pkgs.jq ];
    outputs = [ "out" "layout" ];
  }
  ''
    set -euo pipefail
    labels=(${quoted (p: p.label)})
    fstypes=(${quoted (p: p.fs)})
    codes=(${quoted (p: typeCode.${p.fs})})
    # Passed in, never generated: sgdisk randomises both the disk guid and every partition guid,
    # so two builds of one image would differ for no reason anyone can see.
    guids=(${quoted (p: ids.uuid "${name}:part:${p.label}")})
    imgs=(${lib.concatMapStringsSep " " (p: p.img) partitions})

    align=$(( 1024 * 1024 ))
    start="$align"
    json='[]'

    for i in "''${!imgs[@]}"; do
      bytes="$(stat -c%s "''${imgs[$i]}")"
      size=$(( (bytes + align - 1) / align * align ))
      json="$(jq -c --argjson s "$start" --argjson z "$size" \
        --arg l "''${labels[$i]}" --arg f "''${fstypes[$i]}" \
        '. + [{label:$l, fs:$f, startByte:$s, sizeByte:$z}]' <<<"$json")"
      start=$(( start + size ))
    done

    truncate -s "$(( start + align ))" "$out"
    sgdisk -Z "$out" >/dev/null
    sgdisk -U ${lib.escapeShellArg (ids.uuid "${name}:disk")} "$out" >/dev/null

    for i in "''${!imgs[@]}"; do
      n=$(( i + 1 ))
      s="$(jq -r ".[$i].startByte" <<<"$json")"
      z="$(jq -r ".[$i].sizeByte"  <<<"$json")"
      sgdisk -n "$n:$(( s / 512 )):+$(( z / 512 ))" \
             -t "$n:''${codes[$i]}" -c "$n:''${labels[$i]}" \
             -u "$n:''${guids[$i]}" "$out" >/dev/null
      dd if="''${imgs[$i]}" of="$out" bs=1M seek=$(( s / 1024 / 1024 )) \
         conv=notrunc status=none
    done

    sgdisk -v "$out" >/dev/null
    printf '%s' "$json" | jq . > "$layout"
  ''
