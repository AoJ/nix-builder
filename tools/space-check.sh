# space-check <dir> <size> <what> — refuse a large write before it starts when <dir>'s filesystem
# has less free space than <size> (a qemu-img size: 512M, 4G, …). A write that runs out of space
# halfway can hang instead of failing — a zfs pool inside a VM suspends all its I/O on the error —
# so the shortfall is named up front.
set -euo pipefail

dir=${1:?usage: space-check <dir> <size> <what>}
size=${2:?usage: space-check <dir> <size> <what>}
what=${3:?usage: space-check <dir> <size> <what>}

sc=0
need="$(numfmt --from=iec "$size")" || sc=$?
[ "$sc" -eq 0 ] || fatal "space-check: '$size' is not a size"

sc=0
df_out="$(df --output=avail -B1 "$dir")" || sc=$?
[ "$sc" -eq 0 ] || fatal "space-check: cannot read the free space of $dir"
avail="${df_out##*$'\n'}"
avail="${avail//[[:space:]]/}"

if [ "$avail" -lt "$need" ]; then
  fatal "$what needs up to $size and $dir has $(numfmt --to=iec "$avail") free: refused before writing"
fi
info "$what: up to $size, $(numfmt --to=iec "$avail") free in $dir"
