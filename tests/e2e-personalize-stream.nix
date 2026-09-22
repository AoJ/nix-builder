# The phase-2 chain over the STREAM path: personalize reads the secret-free image and EMITS a
# filled one to stdout, never mutating its input. Booting that emitted image — the exact bytes a
# build server would send to a hypervisor — proves the stream is a real, bootable artifact whose
# slot the running system reads, not merely byte-plausible.
{ pkgs, compose, hosts }:

let
  boot = import ./lib-boot.nix { inherit pkgs; };
  fixture = import ../blocks/personalize/fixture.nix { inherit pkgs; };
  e = compose hosts.ext4;
in
{
  witnesses = [ "ext4.image-personalize" ];
  check = boot {
    name = "e2e-personalize-stream";
    image = e.image-raw.file;
    prepare = ''
      ${pkgs.lib.getExe e.image-personalize.run} disk.img - > streamed.img
      cmp disk.img ${e.image-raw.file}
      mv streamed.img disk.img
      pub="$(${pkgs.age}/bin/age-keygen -y ${fixture}/host.key)"
    '';
    expect = ''
      grep -q "E2E-BOOT-OK e2e-ext4" result
      grep -q "E2E-DB-OK" result
      grep -q "E2E-KEY $pub" result
    '';
  };
}
