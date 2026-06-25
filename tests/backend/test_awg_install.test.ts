import { describe, expect, it } from "bun:test";
import { useGuest } from "../helpers/guest.ts";
import { exec } from "../helpers/ssh.ts";

// Tests for the awg_warp plugin:
//   A) awg_install rpcd method — thin wrapper that runs awg-provision.sh.
//   B) awg-provision.sh directly — key fetch, feed idempotency, injection abort.
//   C) plugin ACL guard — acl.d matches init.uc register() declaration.

const WORK = process.env.SB_VM_WORK ?? "/tmp/work";
const LIB =
  process.env.SB_VM_LIB ?? "/tmp/work/singbox-ui/root/usr/share/singbox-ui/lib";
const HANDLER = `${WORK}/singbox-ui/root/usr/libexec/rpcd/singbox-ui`;
// Plugin source tree (flat lib/ layout after R1 restructure).
const PLUGIN_SRC = `${WORK}/plugins/awg_warp/lib`;
const PLUGIN_ACL_SRC = `${WORK}/plugins/awg_warp/root/usr/share/rpcd/acl.d/singbox-ui-plugin-awg_warp.json`;
// Provisioning script source path.
const PROVISION_SH = `${WORK}/plugins/awg_warp/root/usr/libexec/singbox-ui/awg-provision.sh`;

// ---------------------------------------------------------------------------
// A) awg_install rpcd wrapper: delegates to the provision script
// ---------------------------------------------------------------------------
describe("awg_install rpcd wrapper", () => {
  useGuest();

  it("invokes SB_AWG_PROVISION script and returns ok on exit 0", async () => {
    const r = await exec(`
      set -e
      cleanup() { rm -rf "${LIB}/plugins/awg_warp" /tmp/prov_called; }
      trap cleanup EXIT

      mkdir -p "${LIB}/plugins/awg_warp" && cp -r "${PLUGIN_SRC}"/. "${LIB}/plugins/awg_warp"/
      # Stage protocols/ sub-directory so the descriptor require() resolves.
      mkdir -p "${LIB}/plugins/awg_warp/protocols"
      cp -r "${PLUGIN_SRC}/protocols"/. "${LIB}/plugins/awg_warp/protocols"/ 2>/dev/null || true

      # Stub provision script: records it was called, exits 0.
      # Emits progress lines to stdout to verify rpcd wrapper suppresses them.
      cat > /tmp/fake_provision.sh <<'PROV'
#!/bin/sh
echo "provision called" > /tmp/prov_called
echo "fetching..."
echo "Installing kmod-amneziawg..."
exit 0
PROV
      chmod +x /tmp/fake_provision.sh

      out=$(echo '{}' | \
        SB_AWG_PROVISION=/tmp/fake_provision.sh \
        UCODE_APP_LIB_DIR="${LIB}" \
        ucode -L "${LIB}" "${HANDLER}" call awg_install)

      printf '%s\n' "$out"
      echo "prov_called=$(test -f /tmp/prov_called && cat /tmp/prov_called || echo 'no')"
    `);
    expect(r.exitCode).toBe(0);

    // The provision stub emits progress lines to stdout. With the >/dev/null 2>&1
    // suppression in init.uc, those lines must NOT appear in the rpcd response.
    // The raw captured output must be parseable as JSON directly (no leading apk text).
    const rawOut =
      r.stdout
        .split("\n")
        .find((l) => l.trim() !== "" && !l.startsWith("prov_called=")) ?? "";
    expect(rawOut).toBeTruthy();
    // Must not contain progress lines that the stub printed.
    expect(rawOut).not.toContain("fetching...");
    expect(rawOut).not.toContain("Installing kmod-amneziawg");
    // Must be clean parseable JSON.
    const o = JSON.parse(rawOut);
    expect(o.status).toBe("ok");

    expect(r.stdout).toContain("provision called");
  });

  it("returns error when provision script exits non-zero", async () => {
    const r = await exec(`
      set -e
      cleanup() { rm -rf "${LIB}/plugins/awg_warp"; }
      trap cleanup EXIT

      mkdir -p "${LIB}/plugins/awg_warp" && cp -r "${PLUGIN_SRC}"/. "${LIB}/plugins/awg_warp"/
      mkdir -p "${LIB}/plugins/awg_warp/protocols"
      cp -r "${PLUGIN_SRC}/protocols"/. "${LIB}/plugins/awg_warp/protocols"/ 2>/dev/null || true

      cat > /tmp/fail_provision.sh <<'PROV'
#!/bin/sh
echo "awg-provision: ERROR: something failed" >&2
exit 1
PROV
      chmod +x /tmp/fail_provision.sh

      out=$(echo '{}' | \
        SB_AWG_PROVISION=/tmp/fail_provision.sh \
        UCODE_APP_LIB_DIR="${LIB}" \
        ucode -L "${LIB}" "${HANDLER}" call awg_install)

      printf '%s\n' "$out"
    `);
    expect(r.exitCode).toBe(0);

    const firstLine = r.stdout
      .split("\n")
      .find((l) => l.trim().startsWith("{"));
    expect(firstLine).toBeTruthy();
    const o = JSON.parse(firstLine ?? "{}");
    expect(o.status).toBe("error");
  });
});

// ---------------------------------------------------------------------------
// B) awg-provision.sh — direct tests
// ---------------------------------------------------------------------------
describe("awg-provision.sh", () => {
  useGuest();

  it("fetches key, adds feed line, runs apk add with kmod-amneziawg", async () => {
    const r = await exec(`
      set -e
      TKEYS=$(mktemp -d)
      TREPOS=$(mktemp -d)
      TREL=$(mktemp)
      cleanup() {
        rm -rf "$TKEYS" "$TREPOS" "$TREL"
        rm -f /tmp/fake_wget_ok /tmp/fake_apk_ok /tmp/prov_apk_log /tmp/prov_wget_log
      }
      trap cleanup EXIT

      printf "DISTRIB_RELEASE='25.12.4'\\nDISTRIB_TARGET='x86/64'\\n" > "$TREL"
      : > /tmp/prov_apk_log
      : > /tmp/prov_wget_log

      cat > /tmp/fake_wget_ok <<'STUB'
#!/bin/sh
printf '%s\n' "$*" >> /tmp/prov_wget_log
shift          # skip -O
dest="$1"      # dest path
printf '-----BEGIN PUBLIC KEY-----\nstub\n-----END PUBLIC KEY-----\n' > "$dest"
exit 0
STUB
      chmod +x /tmp/fake_wget_ok

      cat > /tmp/fake_apk_ok <<'STUB'
#!/bin/sh
printf '%s\n' "$*" >> /tmp/prov_apk_log
exit 0
STUB
      chmod +x /tmp/fake_apk_ok

      AWG_OWRT_RELEASE="$TREL" \
      AWG_KEYS_DIR="$TKEYS" \
      AWG_REPOS_D="$TREPOS" \
      WGET_CMD=/tmp/fake_wget_ok \
      APK_CMD=/tmp/fake_apk_ok \
      sh "${PROVISION_SH}"

      keyc=$(ls "$TKEYS" | wc -l | tr -d ' ')
      feed_in_list=$(grep -c "slava-shchipunov" "$TREPOS/awg.list" 2>/dev/null || echo 0)
      kmod_added=$(grep -c "kmod-amneziawg" /tmp/prov_apk_log 2>/dev/null || echo 0)

      echo "keyc=$keyc feed_in_list=$feed_in_list kmod_added=$kmod_added"
    `);
    expect(r.exitCode).toBe(0);

    const keyc = Number(r.stdout.match(/keyc=(\d+)/)?.[1] ?? 0);
    const feedInList = Number(r.stdout.match(/feed_in_list=(\d+)/)?.[1] ?? 0);
    const kmodAdded = Number(r.stdout.match(/kmod_added=(\d+)/)?.[1] ?? 0);

    expect(keyc).toBeGreaterThan(0);
    expect(feedInList).toBeGreaterThan(0);
    expect(kmodAdded).toBeGreaterThan(0);
  });

  it("idempotent: running twice yields exactly one feed line in awg.list", async () => {
    const r = await exec(`
      set -e
      TKEYS=$(mktemp -d)
      TREPOS=$(mktemp -d)
      TREL=$(mktemp)
      cleanup() { rm -rf "$TKEYS" "$TREPOS" "$TREL" /tmp/fake_wget_idem /tmp/fake_apk_idem; }
      trap cleanup EXIT

      printf "DISTRIB_RELEASE='25.12.4'\\nDISTRIB_TARGET='x86/64'\\n" > "$TREL"

      cat > /tmp/fake_wget_idem <<'STUB'
#!/bin/sh
shift          # skip -O
dest="$1"
printf '-----BEGIN PUBLIC KEY-----\nstub\n-----END PUBLIC KEY-----\n' > "$dest"
exit 0
STUB
      chmod +x /tmp/fake_wget_idem

      cat > /tmp/fake_apk_idem <<'STUB'
#!/bin/sh
exit 0
STUB
      chmod +x /tmp/fake_apk_idem

      AWG_OWRT_RELEASE="$TREL" AWG_KEYS_DIR="$TKEYS" AWG_REPOS_D="$TREPOS" \
        WGET_CMD=/tmp/fake_wget_idem APK_CMD=/tmp/fake_apk_idem \
        sh "${PROVISION_SH}"
      AWG_OWRT_RELEASE="$TREL" AWG_KEYS_DIR="$TKEYS" AWG_REPOS_D="$TREPOS" \
        WGET_CMD=/tmp/fake_wget_idem APK_CMD=/tmp/fake_apk_idem \
        sh "${PROVISION_SH}"

      line_count=$(grep -c "slava-shchipunov" "$TREPOS/awg.list" 2>/dev/null || echo 0)
      echo "line_count=$line_count"
    `);
    expect(r.exitCode).toBe(0);

    const lineCount = Number(r.stdout.match(/line_count=(\d+)/)?.[1] ?? 0);
    // Exactly ONE feed line, even after two runs.
    expect(lineCount).toBe(1);
  });

  it("aborts on malicious DISTRIB_TARGET with injection attempt", async () => {
    const r = await exec(`
      TKEYS=$(mktemp -d)
      TREPOS=$(mktemp -d)
      TREL=$(mktemp)
      DAMAGE_FILE=$(mktemp)
      cleanup() { rm -rf "$TKEYS" "$TREPOS" "$TREL" "$DAMAGE_FILE" /tmp/fake_wget_inj /tmp/fake_apk_inj; }
      trap cleanup EXIT

      # Malicious release file: DISTRIB_TARGET contains semicolon + shell injection.
      printf "DISTRIB_RELEASE='25.12.4'\\nDISTRIB_TARGET='x86/64; echo INJECTED > %s'\\n" \
        "$DAMAGE_FILE" > "$TREL"

      cat > /tmp/fake_wget_inj <<'STUB'
#!/bin/sh
shift          # skip -O
dest="$1"
printf '-----BEGIN PUBLIC KEY-----\nstub\n-----END PUBLIC KEY-----\n' > "$dest"
exit 0
STUB
      chmod +x /tmp/fake_wget_inj

      cat > /tmp/fake_apk_inj <<'STUB'
#!/bin/sh
exit 0
STUB
      chmod +x /tmp/fake_apk_inj

      rc=0
      AWG_OWRT_RELEASE="$TREL" AWG_KEYS_DIR="$TKEYS" AWG_REPOS_D="$TREPOS" \
        WGET_CMD=/tmp/fake_wget_inj APK_CMD=/tmp/fake_apk_inj \
        sh "${PROVISION_SH}" 2>&1 || rc=$?

      dmg=$(cat "$DAMAGE_FILE" 2>/dev/null | tr -d '\\n' || echo "")
      echo "exit_rc=$rc"
      echo "damage=$dmg"
    `);
    // Script must exit non-zero (validation failure).
    const exitRc = Number(r.stdout.match(/exit_rc=(\d+)/)?.[1] ?? 0);
    expect(exitRc).toBeGreaterThan(0);

    // No injection side-effect: the damage file must NOT contain INJECTED.
    const damage = r.stdout.match(/damage=(.*)/)?.[1]?.trim() ?? "";
    expect(damage).not.toContain("INJECTED");
  });
});

// ---------------------------------------------------------------------------
// C) plugin ACL guard
// ---------------------------------------------------------------------------
describe("plugin ACL guard", () => {
  useGuest();

  it("plugin acl.d read∪write set matches init.uc register() declaration", async () => {
    // Read the plugin's own acl.d file directly (no staging needed).
    // Asserts exact match: read={awg_status}, write={awg_install}.
    const r = await exec(`
      set -e
      ucode -e '
        let fs = require("fs");
        let f = "${PLUGIN_ACL_SRC}";
        let d = json(fs.readfile(f) || "{}");
        let entry = d["singbox-ui-plugin-awg_warp"] ?? {};
        let read_arr  = ((entry.read  ?? {}).ubus ?? {})["singbox-ui"] ?? [];
        let write_arr = ((entry.write ?? {}).ubus ?? {})["singbox-ui"] ?? [];
        let all_arr   = [];
        for (let m in read_arr)  push(all_arr, m);
        for (let m in write_arr) push(all_arr, m);
        printf("%J\n", { read: read_arr, write: write_arr, all: all_arr });
      '
    `);
    expect(r.exitCode).toBe(0);

    const firstLine = r.stdout
      .split("\n")
      .find((l) => l.trim().startsWith("{"));
    expect(firstLine).toBeTruthy();
    const { read, write, all } = JSON.parse(firstLine ?? "{}") as {
      read: string[];
      write: string[];
      all: string[];
    };

    // Exact match with what init.uc passes to reg.register().
    expect([...read].sort()).toEqual(["awg_status"]);
    expect([...write].sort()).toEqual(["awg_install"]);
    // No overlap between read and write.
    for (const m of read) {
      expect(write.includes(m)).toBe(false);
    }
    // All 2 methods present.
    expect(all.length).toBe(2);
  });
});
