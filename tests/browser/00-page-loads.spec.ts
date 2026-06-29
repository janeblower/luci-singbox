// 00-page-loads.spec.ts — smoke: the singbox-ui page renders without errors.
import { assert, clickSubTab, clickTopTab, test } from "./fixtures";

export const COVERS = [
  "tab.inbounds",
  "tab.outbounds",
  "tab.route",
  "tab.dns",
  "tab.dashboard",
  "tab.monitoring",
  "tab.general",
  "subtab.routerules",
  "subtab.rulesets",
  "subtab.routedef",
];

test("page loads", async ({ page, pageerrors }) => {
  const title = await page.title();
  assert("title contains Singbox-UI", /Singbox-UI/i.test(title), title);

  const sectionExists =
    (await page.locator("#cbi-singbox-ui-inbound").count()) > 0;
  assert("inbound section rendered", sectionExists);

  const outboundExists =
    (await page.locator("#cbi-singbox-ui-outbound").count()) > 0;
  assert("outbound section rendered", outboundExists);

  // Critical errors from prior bugs we explicitly regressed.
  const fatalish = pageerrors.filter(
    (e) =>
      /Tab already declared/i.test(e) ||
      /Cannot read properties of undefined/i.test(e),
  );
  assert(
    "no prior-regression errors",
    fatalish.length === 0,
    fatalish.join("\n"),
  );
});

test("page: top tabs switch and route sub-tabs switch", async ({ page }) => {
  for (const t of [
    "inbounds",
    "outbounds",
    "route",
    "dns",
    "dashboard",
    "monitoring",
    "general",
  ]) {
    const ok = await clickTopTab(page, t);
    assert(`top tab clickable: ${t}`, ok, t);
  }
  await clickTopTab(page, "route");
  for (const st of ["routerules", "rulesets", "routedef"]) {
    const ok = await clickSubTab(page, st);
    assert(`route sub-tab clickable: ${st}`, ok, st);
  }
});
