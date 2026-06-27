# tests/docker — qemu-OpenWrt test image scaffolding

This directory holds the source for the **published test image**
`ghcr.io/<owner>/luci-singbox/openwrt-test`, used by CI and by
`tests/run-vm.sh` locally.

## Architecture: in-guest bun execution

`bun test tests/backend tests/parity` runs **inside** the OpenWrt QEMU guest,
not on the container host. The flow each run:

1. `entrypoint.sh` boots the guest from the `boot-state` snapshot (~3-5s).
2. The working tree is tar-streamed into the guest via SSH.
3. The musl-baseline bun binary (`/opt/bun-guest/bun` in the image) is
   **streamed** via SSH into the guest's `/tmp/bun` (tmpfs) — no persistent
   install.
4. `entrypoint.sh` kicks a single in-guest `bun test` over SSH with
   `SINGBOX_TESTS_IN_VM=1` set, then propagates the exit code.

`SINGBOX_TESTS_IN_VM=1` is the marker test helpers (`tests/helpers/ssh.ts`)
check: when set, `exec`/`putFile` become local spawn/write inside the guest
process rather than SSH calls, so the ~48 backend/parity test files are
**unchanged** — the helper's exported API is identical in both modes.

SSH is used only by `entrypoint.sh` as the orchestration transport
(tree + bun streaming, one `bun test` invocation). It is absent from all
test-logic paths.

## Why musl-baseline bun

The snapshot boots a `qemu64` CPU which has no AVX2. The standard bun build
uses AVX2 and SIGILLs on this CPU; the `bun-linux-x64-musl-baseline` asset
does not and runs correctly. This is a hard requirement — do not swap to the
non-baseline asset.

## Files

- `Dockerfile` — image definition. Bakes OpenWrt 25.12.3 rootfs + a QEMU
  memory snapshot of post-boot state. Guest-side bun is a **trailing layer**
  after the snapshot bake (see below). Final size ~150-200 MB.
- `build-snapshot.sh` + `build-snapshot.expect` — image-build-time helper
  that boots qemu at `-m 1G`, dialogues over serial to set the root password,
  installs sing-box and `libstdcpp6` (bun links GNU libstdc++, absent from
  stock OpenWrt), then issues `savevm boot-state` via the qemu monitor.
  `libstdcpp6` persists in the overlay and is baked into `base.qcow2`.
- `entrypoint.sh` — container ENTRYPOINT for the published image. Copies the
  qcow2 overlay, boots qemu at `-m 1G` with `-loadvm boot-state`, tar-streams
  the working tree, streams bun into guest `/tmp/bun`, then runs
  `SINGBOX_TESTS_IN_VM=1 PATH=/tmp:$PATH /tmp/bun test tests/backend
  tests/parity` in-guest and propagates the exit code.  
  **Note:** `-m 1G` must match the `savevm` memory size — `-loadvm` rejects
  a mismatch.
- `wait-ssh.sh` — polls `127.0.0.1:2222` until SSH responds.

## Guest-side bun: trailing Docker layer

`BUN_VERSION` in `Dockerfile` pins the bun version. The guest bun download
(`bun-linux-x64-musl-baseline`) is fetched in a **separate `RUN` layer placed
after the snapshot bake** so that bumping `BUN_VERSION` only rebuilds that one
layer — the `KVM`-requiring `build-snapshot.sh` step is not re-executed.

The version single-source is enforced by `tests/cross/test_guest_bun_version.test.ts`.

## RAM: 1G, matched across savevm and loadvm

Guest RAM is `-m 1G`, set identically in `build-snapshot.sh` (savevm) and
`entrypoint.sh` (loadvm). The full suite (656 tests) fits comfortably; this
is confirmed sufficient with no OOM. Do not change one without the other.

## Local development

Build the image locally (requires `/dev/kvm`):

    docker buildx build \
      --builder singbox-insecure \
      --allow security.insecure \
      --build-arg OPENWRT_VERSION=$(cat tests/docker/openwrt-version.txt) \
      -t local-openwrt-test:bun-guest \
      --load tests/docker

Run the suite against the local image (skips `docker pull` when
`SINGBOX_TEST_IMAGE` is set):

    SINGBOX_TEST_IMAGE=local-openwrt-test:bun-guest sh tests/run-vm.sh

## Bumping the OpenWrt version

1. Pull the new SHA256 from
   `https://downloads.openwrt.org/releases/<X.Y.Z>/targets/x86/64/sha256sums`.
2. Update `openwrt-version.txt` and `IMAGE_SHA256` in `Dockerfile`.
3. Trigger the `test-image` workflow manually (`Actions → test-image →
   Run workflow`).
4. After the new image is published, the next merge into `main` picks it
   up via the moving `:latest` tag.

## Bumping the bun version

1. Set `BUN_VERSION` in `Dockerfile` to the new version.
2. Trigger the `test-image` workflow — only the trailing bun layer is
   rebuilt (no KVM required, fast).
3. `tests/cross/test_guest_bun_version.test.ts` is a static read of the
   Dockerfile (single `BUN_VERSION` source, baseline asset URL pinned to it),
   so it passes as soon as step 1 is consistent — it does NOT check the
   published image. The new bun only takes effect once the `test-image`
   workflow republishes the image and CI pulls it; the entrypoint's runtime
   `--version`-vs-`/opt/bun-guest/VERSION` guard then confirms the match.

## Debugging a stuck guest

Inside the container, qemu exposes:
- `/tmp/qemu-serial.sock` — serial console (connect via
  `socat - UNIX-CONNECT:/tmp/qemu-serial.sock`)
- `/tmp/qemu-monitor.sock` — qemu monitor (HMP)

To keep the container alive after a test failure for inspection, pass
`-e KEEP_VM=1` to `docker run` — entrypoint will sleep on test failure
instead of exiting.
