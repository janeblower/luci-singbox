import { afterAll, beforeAll, describe, expect, it } from "bun:test";
import { useGuest } from "../helpers/guest.ts";
import { goldenDrift } from "../helpers/parity.ts";
import { exec } from "../helpers/ssh.ts";
import { runUcodeJSON } from "../helpers/ucode.ts";

const WORK = process.env.SB_VM_WORK ?? "/tmp/work";

// The plugin's source lib tree is flat (plugins/awg_warp/lib/{init,iface,…}.uc
// + lib/protocols/awg_warp.uc), but the require names are namespaced as
// `plugins.awg_warp.*`. ucode resolves `-L <root>` + `plugins.awg_warp.X` to
// `<root>/plugins/awg_warp/X.uc`, so we stage the flat lib tree under a synthetic
// lib ROOT (`<root>/plugins/awg_warp/`) and pass that root as the extra -L dir.
// (Staging into a private dir — not the shared LIB — keeps discovery guards clean.)
const PLUGIN_LIB_ROOT = ".awg-parity-lib";
const PLUGIN_SRC = `${WORK}/plugins/awg_warp/lib`;

// One ucode round-trip builds every corpus fixture into a {name: built} map;
// the host deep-compares each against its golden JSON file (helpers/parity.ts).

// The driver requires "corpus" from tests/parity (extra lib dir) and runs
// outbound/inbound builder for every fixture, returning a flat map.
const DRIVER = `
  let corpus = require("corpus");
  let ob = require("outbound");
  let inb = require("inbound");
  let res = {};
  for (let fx in corpus) {
    res[fx.name] = (fx.kind === "outbound")
      ? ob.build_constructor_for(fx.section, fx.type)
      : inb.build_one(fx.section);
  }
  print(sprintf("%J", res));
`;

describe("protocol parity", () => {
  useGuest();

  beforeAll(async () => {
    const dst = `${WORK}/${PLUGIN_LIB_ROOT}/plugins/awg_warp`;
    await exec(
      `rm -rf "${WORK}/${PLUGIN_LIB_ROOT}"; mkdir -p "${dst}"; cp -r "${PLUGIN_SRC}"/. "${dst}"/`,
    );
  });

  afterAll(async () => {
    await exec(`rm -rf "${WORK}/${PLUGIN_LIB_ROOT}"`);
  });

  it("every corpus fixture deep-equals its golden", async () => {
    // corpus.uc lives in tests/parity, so pass it as extraLibDirs.
    // The AWG-WARP plugin descriptor lives in the plugin package's lib tree;
    // add the staged plugin lib ROOT (see PLUGIN_LIB_ROOT above) as a second
    // extra lib dir so require("plugins.awg_warp.protocols.awg_warp") in corpus.uc
    // can find it (explicit require — that is what registers the type).
    // ISOLATION (why the ACL/rpcd guards stay clean even though init.uc DOES exist
    // in that plugin lib tree): plugins.discovery.load_all() does NOT use the `-L`
    // module-search path — it `fs.glob`s the SYSTEM filesystem path
    // `/usr/share/singbox-ui/lib/plugins/*/init.uc` (lib_root() default, since
    // UCODE_APP_LIB_DIR is unset here). The staged plugin tree is only reachable via
    // `-L`, never installed at that system path, so the glob never finds
    // awg_warp/init.uc and the handler never advertises the plugin's rpcd methods.
    // Shell equivalent: ucode -L tests/parity -L "<plugin-lib-root>" -L "$LIB" -e '...'
    const built = await runUcodeJSON<Record<string, unknown>>(
      DRIVER,
      [],
      ["tests/parity", PLUGIN_LIB_ROOT],
    );

    expect(goldenDrift(built)).toEqual([]);
  });
});
