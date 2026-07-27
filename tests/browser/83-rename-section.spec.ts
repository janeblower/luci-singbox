// 83-rename-section.spec.ts — renaming a section through the modal's "Name"
// field, against the LuCI that actually ships.
//
// This test exists because a unit test could NOT catch the bug it guards.
// addRenameField called `uci.rename('singbox-ui', sid, value)`. LuCI's uci API
// has NO rename — createSID / resolveSID / add / clone / remove / get / set /
// unset / sections / move, and the word only appears in doc comments — so every
// rename was a TypeError on a real router. And because renameRefs() ran FIRST,
// each attempt had ALREADY repointed every by-name reference (route rules, group
// members, detours, dns.final, domain_resolver) at a name that then never came
// into existence; the next Save & Apply flushed that. For a rule-set the damage
// is silent and total: tun.route_address_set is a WHITELIST, and an empty one
// means the tunnel swallows the whole address space.
//
// The unit test was green throughout, because its uci stub provided a `rename`
// method — i.e. it validated the author's idea of LuCI instead of LuCI. That is
// exactly the trap CLAUDE.md records for renderRowActions.
//
// What is asserted here is what the user gets:
//   * the section really is renamed on disk (old id gone, new id present),
//   * the other fields edited in the SAME modal survive the rename (they are
//     parsed after "Name", into an id that must still exist at that moment),
//   * a reference from another section follows the rename.
import {
  test,
  assert,
  wait,
  clickTopTab,
  openEditModalBySid,
  fillField,
  saveAndReload,
  containerExec,
} from "./fixtures";

export const COVERS = ["grid.section.rename"];

const OLD = "_rn_src";
const NEW = "_rn_dst";
const REF = "_rn_ref";

test("renaming an outbound moves the section and drags its references along", async ({
  page,
}) => {
  // vless, not direct: the grid section carries EVERY protocol's fields (gated by
  // depends), so a "Server" row exists in the DOM even for a direct outbound —
  // it is simply inactive, and LuCI's parse() skips inactive options. Editing it
  // there would prove nothing. vless is a protocol that really owns `server`.
  containerExec(
    `uci -q delete singbox-ui.${OLD}; uci -q delete singbox-ui.${NEW}; uci -q delete singbox-ui.${REF};
     uci set singbox-ui.${OLD}=outbound; uci set singbox-ui.${OLD}.type=vless;
     uci set singbox-ui.${OLD}.enabled=1;
     uci set singbox-ui.${OLD}.server=old.example;
     uci set singbox-ui.${OLD}.server_port=443;
     uci set singbox-ui.${OLD}.server_uuid=11111111-2222-3333-4444-555555555555;
     uci set singbox-ui.${REF}=route_rule; uci set singbox-ui.${REF}.enabled=1;
     uci set singbox-ui.${REF}.type=default; uci set singbox-ui.${REF}.action=route;
     uci set singbox-ui.${REF}.outbound=${OLD}; uci add_list singbox-ui.${REF}.domain_suffix=.example;
     uci commit singbox-ui`,
  );
  await clickTopTab(page, "outbounds");
  await page.reload({ waitUntil: "networkidle" });
  await wait(2500);

  await openEditModalBySid(page, "outbound", OLD);
  // "Name" is declared FIRST in the modal, so it is also parsed first: whatever
  // this rename does must leave the following options writable.
  await fillField(page, "Name", NEW);
  await fillField(page, "Server", "renamed.example");
  await saveAndReload(page);

  const oldType = containerExec(`uci -q get singbox-ui.${OLD} || echo GONE`).trim();
  assert("old section id is gone", oldType === "GONE", oldType);

  const newType = containerExec(`uci -q get singbox-ui.${NEW} || echo MISSING`).trim();
  assert("new section id exists as an outbound", newType === "outbound", newType);

  // The sibling option written AFTER "Name" in the same modal parse.
  const server = containerExec(
    `uci -q get singbox-ui.${NEW}.server || echo MISSING`,
  ).trim();
  assert("a field saved alongside the rename survived", server === "renamed.example", server);

  // …and the reference from another section followed.
  const ref = containerExec(
    `uci -q get singbox-ui.${REF}.outbound || echo MISSING`,
  ).trim();
  assert("route_rule.outbound follows the rename", ref === NEW, ref);

  containerExec(
    `uci -q delete singbox-ui.${NEW}; uci -q delete singbox-ui.${REF}; uci commit singbox-ui`,
  );
});
