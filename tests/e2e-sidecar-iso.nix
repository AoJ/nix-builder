# The iso sidecar CONSUMER path — the one real usage walks and the suite skipped. A vfat
# sidecar is found by the constant label SECRETS, so a marker can restate it literally; an iso
# sidecar's label is name-DERIVED, so a host can only find it by deriving it the same way the
# medium was stamped. Here the booted host does exactly that (the label threaded into its
# marker from builder.lib's ids), mounts the attached medium by it, and re-derives the key. A
# drift between derived and stamped would fail this mount — which is why it must be a boot, not
# an eval.
{ pkgs, compose, hosts }:

let
  inherit (pkgs) lib;
  boot = import ./lib-boot.nix { inherit pkgs; };
  fixture = import ../blocks/personalize/fixture.nix { inherit pkgs; };
  e = compose hosts.ext4;
in
{
  witnesses = [ "ext4.image-secrets-iso" ];
  check = boot {
    name = "e2e-sidecar-iso";
    image = e.image-raw.file;
    prepare = ''
      ${lib.getExe e.image-secrets-iso.run} sidecar.iso
      pub="$(${pkgs.age}/bin/age-keygen -y ${fixture}/host.key)"
    '';
    extraDrives = "-drive if=virtio,format=raw,file=sidecar.iso";
    expect = ''
      grep -q "E2E-BOOT-OK e2e-ext4" result
      grep -q "E2E-SIDECAR-ISO $pub" result
    '';
  };
}
