import { execSync } from "node:child_process";
import { existsSync, readFileSync, statSync } from "node:fs";
import { join, resolve } from "node:path";
import { describe, expect, it } from "vitest";

// tests/cross/test_rpcd_handler.sh
// Shebang invariant: rpcd invokes the handler via its shebang on the target,
// so `-L /usr/share/singbox-ui/lib` MUST be on the interpreter line. Without
// it, in-handler `require("scrub")` / `require("builder.protocols.schema_dump")` /
// `require("reveal")` calls fail at runtime and methods like preview_config
// and protocol_schema return `require(...) failed` (regression: shebang was
// bare `#!/usr/bin/ucode` until this assertion was added). The Linux kernel
// treats everything after the interpreter as a single argv string, so the
// `-L` and its path must NOT be separated by a space — `-Lpath` form is the
// only one getopt can parse out of a shebang.

const REPO = resolve(import.meta.dirname, "../..");
const SB_BACKEND_ROOT = join(REPO, "singbox-ui/root");
const H = join(SB_BACKEND_ROOT, "usr/libexec/rpcd/singbox-ui");

// Detect ucode availability for the ucode-gated runtime section
const ucodeAvailable = (() => {
  try {
    execSync("command -v ucode", { stdio: "pipe", shell: "/bin/sh" });
    return true;
  } catch {
    return false;
  }
})();

describe("test_rpcd_handler", () => {
  it("rpcd handler file exists", () => {
    expect(existsSync(H)).toBe(true);
  });

  it("rpcd handler is executable", () => {
    const st = statSync(H);
    // Check executable bit (owner execute)
    expect((st.mode & 0o111) !== 0).toBe(true);
  });

  // Shebang invariant — host-only file read, no ucode needed.
  it("shebang is exactly '#!/usr/bin/ucode -L/usr/share/singbox-ui/lib' (no space before path)", () => {
    const src = readFileSync(H, "utf8");
    const firstLine = src.split("\n")[0];
    expect(firstLine).toBe("#!/usr/bin/ucode -L/usr/share/singbox-ui/lib");
  });

  // Ucode-gated: the runtime `list` method test — skip when ucode is absent.
  // The .sh runs `ucode -L lib handler list` (no ubus needed) and asserts:
  //   - critical methods present: generate, nftables, refresh, clash_get, …
  //   - clash_request ABSENT (removed from the dispatcher)
  it.skipIf(!ucodeAvailable)(
    "ucode-gated: handler list method returns JSON with expected methods",
    () => {
      const SB_LIB = join(SB_BACKEND_ROOT, "usr/share/singbox-ui/lib");
      // `list` does not need ubus — invoke the handler directly via ucode.
      const output = execSync(`echo '{}' | ucode -L "${SB_LIB}" "${H}" list`, {
        encoding: "utf8",
        timeout: 10000,
      });
      // Must parse as valid JSON.
      const parsed = JSON.parse(output.trim());

      // Methods that MUST be present (from the shell's `je 'd.X != null'` checks).
      for (const m of [
        "generate",
        "nftables",
        "restart",
        "refresh",
        "status",
        "status_detail",
        "read_config",
        "clash_get",
        "clash_mutate",
        "export_section",
        "preview_config",
      ]) {
        expect(parsed, `missing method: ${m}`).toHaveProperty(m);
      }
      // Spot-check a few argument shapes the shell also asserted.
      expect(parsed.nftables, "nftables.action missing").toHaveProperty(
        "action",
      );
      expect(parsed.refresh, "refresh.what missing").toHaveProperty("what");
      expect(
        parsed.export_section,
        "export_section.kind missing",
      ).toHaveProperty("kind");
      expect(
        parsed.export_section,
        "export_section.name missing",
      ).toHaveProperty("name");

      // clash_request MUST be absent (shell: `je 'd.clash_request == null'`).
      expect(parsed).not.toHaveProperty("clash_request");
    },
  );
});
