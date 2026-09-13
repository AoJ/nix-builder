# Identity for an artifact, derived from its name.
#
# Generated ids make two builds of one image differ. A shared constant is worse: two DIFFERENT
# images then answer the same by-uuid lookup, which only shows up on a machine. nixpkgs ships
# that failure — every ISO carries label EFIBOOT and fs uuid 1234-5678.
let
  hex = s: builtins.hashString "sha256" s;
  slice =
    s: start: len:
    builtins.substring start len (hex s);
in
{
  # 8-4-4-4-12, for mke2fs -U and sgdisk -U/-u.
  uuid = s: "${slice s 0 8}-${slice s 8 4}-${slice s 12 4}-${slice s 16 4}-${slice s 20 12}";

  # mkfs.fat -i takes a 32-bit volume id as 8 hex digits.
  volumeId = s: slice s 0 8;
}
