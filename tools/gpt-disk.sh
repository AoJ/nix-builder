# gpt-disk — write a GPT disk image from already-built partition images. No loop device, no
# root: sgdisk writes the table into a plain file and the partition images are dd'd to their
# own offsets. This is the whole reason the image path needs no VM.
#
#   gpt-disk <out> <layout-json> <disk-guid> <manifest>
#
# manifest: one `<name>\t<typecode>\t<fs>\t<image>\t<part-guid>` line per partition, in
# order. The layout as BUILT is emitted to <layout-json> so a consumer reads it instead of
# restating it.
#
# Every GUID is passed in, never generated: sgdisk would otherwise randomise them and two
# builds of the same image would differ for no reason anyone can see.
set -euo pipefail

out=${1:?usage: gpt-disk <out> <layout-json> <disk-guid> <manifest>}
layout=${2:?missing layout output path}
disk_guid=${3:?missing disk guid}
manifest=${4:?missing manifest}

[ -f "$manifest" ] || fatal "gpt-disk: no such manifest: $manifest"

sector=512
align=$((1024 * 1024))

names=()
images=()
starts=()
args=()
json='[]'

index=0
cursor=$align
while IFS=$'\t' read -r name typecode fs image guid; do
  [ -n "$name" ] || continue
  index=$((index + 1))
  [ -f "$image" ] || fatal "gpt-disk: partition '$name' image missing: $image"
  sc=0
  bytes=$(stat -Lc %s "$image") || sc=$?
  [ "$sc" = 0 ] || fatal "gpt-disk: cannot stat '$image'"
  [ "$bytes" -gt 0 ] || fatal "gpt-disk: partition '$name' would be empty"
  bytes=$(((bytes + sector - 1) / sector * sector))

  start=$cursor
  end=$((start + bytes))
  cursor=$(((end + align - 1) / align * align))

  names+=("$name")
  images+=("$image")
  starts+=("$start")
  args+=(-n "$index:$((start / sector)):$((end / sector - 1))")
  args+=(-t "$index:$typecode")
  args+=(-c "$index:$name")
  args+=(-u "$index:$guid")
  sc=0
  json=$(jq -c --argjson s "$start" --argjson z "$bytes" --arg l "$name" --arg f "$fs" \
    '. + [{label: $l, fs: $f, startByte: $s, sizeByte: $z}]' <<<"$json") || sc=$?
  [ "$sc" = 0 ] || fatal "gpt-disk: layout row for '$name' failed"
  info "part $index $name: $((bytes / 1024 / 1024)) MiB at $((start / sector))s"
done < "$manifest"

[ "$index" -gt 0 ] || fatal "gpt-disk: empty manifest"

# One alignment unit of tail for the backup GPT.
truncate -s "$((cursor + align))" "$out"
run "sgdisk" sgdisk -U "$disk_guid" "${args[@]}" "$out"

for i in "${!names[@]}"; do
  run "write ${names[$i]}" dd if="${images[$i]}" of="$out" bs="$sector" \
    seek="$((starts[i] / sector))" conv=notrunc status=none
done

jq . <<<"$json" > "$layout"
