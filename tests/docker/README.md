# tests/docker — qemu-OpenWrt test image scaffolding

This directory holds the source for the **published test image**
`ghcr.io/<owner>/luci-singbox/openwrt-test`, used by CI and by
`tests/run-vm.sh` locally.

## Files

- `Dockerfile` — image definition. Bakes OpenWrt 25.12.3 rootfs + a qemu
  memory snapshot of post-boot state. Final size ~150-200 MB.
- `build-snapshot.sh` + `build-snapshot.expect` — image-build-time helper
  that boots qemu, dialogues over serial to set the root password and
  install sing-box, then issues `savevm boot-state` via the qemu monitor.
- `entrypoint.sh` — container ENTRYPOINT for the published image. Copies
  the qcow2 overlay, boots qemu with `-loadvm boot-state` (~3-5s vs cold
  ~60-90s), tar-streams the working tree into the guest, runs the suite,
  propagates the exit code.
- `wait-ssh.sh` — polls `127.0.0.1:2222` until SSH responds.

## Local development

Build the image locally (requires `/dev/kvm`):

    docker build -t singbox-test:dev tests/docker/

Run the suite against the local image:

    docker run --rm --device /dev/kvm -v "$PWD:/work" singbox-test:dev

## Bumping the OpenWrt version

1. Pull the new SHA256 from
   `https://downloads.openwrt.org/releases/<X.Y.Z>/targets/x86/64/sha256sums`.
2. Update `IMAGE_URL` and `IMAGE_SHA256` in `Dockerfile`.
3. Trigger the `test-image` workflow manually (`Actions → test-image →
   Run workflow`).
4. After the new image is published, the next merge into `main` picks it
   up via the moving `:latest` tag.

## Debugging a stuck guest

Inside the container, qemu exposes:
- `/tmp/qemu-serial.sock` — serial console (connect via
  `socat - UNIX-CONNECT:/tmp/qemu-serial.sock`)
- `/tmp/qemu-monitor.sock` — qemu monitor (HMP)

To keep the container alive after a test failure for inspection, pass
`-e KEEP_VM=1` to `docker run` — entrypoint will sleep on test failure
instead of exiting.
