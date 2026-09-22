# Identity for an artifact, derived from its name.
#
# Generated ids make two builds of one image differ. A shared constant is worse: two DIFFERENT
# images then answer the same by-uuid lookup, which only shows up on a machine. nixpkgs ships
# that failure — every ISO carries label EFIBOOT and fs uuid 1234-5678.
let
  # RFC 4122 pins two nibbles: the version, and the top bits of the variant. Deriving all 32
  # from a hash produces something that every tool here accepts but that is not a uuid, so the
  # two are placed and only the remaining 30 come from the hash.
  variantNibble = {
    "0" = "8"; "1" = "9"; "2" = "a"; "3" = "b";
    "4" = "8"; "5" = "9"; "6" = "a"; "7" = "b";
    "8" = "8"; "9" = "9"; "a" = "a"; "b" = "b";
    "c" = "8"; "d" = "9"; "e" = "a"; "f" = "b";
  };
  # mkfs.fat -i takes a 32-bit volume id as 8 hex digits.
  volumeId = s: builtins.substring 0 8 (builtins.hashString "sha256" s);

  # The same id as iso9660 stamps its volume label — hex uppercased. Pure builtins (the id is
  # hex, so only a-f shift), so a consumer needs no pkgs to derive the label it mounts by.
  volumeIdUpper = s: builtins.replaceStrings
    [ "a" "b" "c" "d" "e" "f" ] [ "A" "B" "C" "D" "E" "F" ]
    (builtins.substring 0 8 (builtins.hashString "sha256" s));
in
{
  # 8-4-4-4-12, for mke2fs -U and sgdisk -U/-u. Version 4, variant 10xx.
  uuid =
    s:
    let
      h = builtins.hashString "sha256" s;
      at = start: len: builtins.substring start len h;
    in
    "${at 0 8}-${at 8 4}-4${at 13 3}-${variantNibble.${at 16 1}}${at 17 3}-${at 20 12}";

  inherit volumeId volumeIdUpper;

  # Named handles: the ONE place each artifact identity's seed lives, so a host config and the
  # block that stamps the medium call the SAME function and cannot drift to different strings.
  # A consumer mounts a sidecar / finds a slot by exactly what these return.
  slotVolumeId = name: volumeId "${name}:slot";
  secretsVolumeId = name: volumeId "${name}:sidecar";
  secretsIsoLabel = name: volumeIdUpper "${name}:sidecar";
  secretsVfatLabel = "SECRETS";
}
