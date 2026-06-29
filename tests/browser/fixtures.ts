import { execSync } from "node:child_process";
import { test as base, expect } from "@playwright/test";

// BROWSER_URL is set by tests/test_browser.sh after launching the Docker
// container, e.g. http://127.0.0.1:34567/cgi-bin/luci. LUCI_USER/PASS
// default to the container-seeded root:admin.
export const BROWSER_URL =
  process.env.BROWSER_URL || "http://127.0.0.1:8080/cgi-bin/luci";
export const LUCI_USER = process.env.LUCI_USER || "root";
export const LUCI_PASS = process.env.LUCI_PASS || "admin";
export const LUCI_URL = BROWSER_URL;
export const PAGE_URL = `${BROWSER_URL}/admin/services/singbox-ui`;
// DOCKER_NAME is set by tests/test_browser.sh; used by containerExec() to
// run UCI/ubus/nft commands inside the test container.
export const DOCKER_NAME = process.env.DOCKER_NAME || "";

interface Fixtures {
  restoreUci: undefined;
  pageerrors: string[];
  page: import("@playwright/test").Page;
}

export const test = base.extend<Fixtures>({
  // Per-test UCI restore: resets singbox-ui UCI to the captured baseline so
  // Playwright specs at workers:1 don't cross-contaminate each other.
  // No-op when DOCKER_NAME is unset (non-browser environments).
  restoreUci: [
    // biome-ignore lint/correctness/noEmptyPattern: Playwright fixture, no deps
    async ({}, use) => {
      if (DOCKER_NAME) {
        containerExec(
          "cp /tmp/uci.baseline /etc/config/singbox-ui 2>/dev/null || true",
        );
        containerExec("/etc/init.d/rpcd reload 2>/dev/null || true");
      }
      await use(undefined);
    },
    { auto: true },
  ],

  // auto fixture: owns the error array; asserts empty on teardown for EVERY test.
  pageerrors: [
    // biome-ignore lint/correctness/noEmptyPattern: Playwright fixture, no deps
    async ({}, use) => {
      const errs: string[] = [];
      await use(errs);
      expect(errs, errs.join("\n")).toEqual([]);
    },
    { auto: true },
  ],

  // replaces newPage(): node-side login -> addCookies(httpOnly) -> goto -> readiness.
  // Depends on pageerrors so the listener is attached BEFORE goto (FIX 3/4/5).
  page: async ({ context, pageerrors }, use) => {
    const root = BROWSER_URL;
    let value = "";
    for (let i = 0; i < 3; i++) {
      // keep 3x ECONNRESET retry
      try {
        const res = await fetch(root, {
          method: "POST",
          redirect: "manual",
          headers: { "content-type": "application/x-www-form-urlencoded" },
          body: `luci_username=${encodeURIComponent(LUCI_USER)}&luci_password=${encodeURIComponent(LUCI_PASS)}`,
        });
        const m = (res.headers.get("set-cookie") || "").match(
          /sysauth_http=([^;]+)/,
        );
        if (m) {
          value = m[1];
          break;
        }
      } catch {
        /* ECONNRESET — retry */
      }
    }
    if (!value) throw new Error("LuCI login failed (no sysauth_http)");
    await context.addCookies([
      {
        name: "sysauth_http",
        value,
        domain: new URL(root).hostname,
        path: "/cgi-bin/luci/",
        httpOnly: true,
      },
    ]);
    const page = await context.newPage();
    page.on("pageerror", (e) => pageerrors.push(`[pageerror] ${e.message}`)); // BEFORE goto
    await page.goto(`${BROWSER_URL}/admin/services/singbox-ui`, {
      waitUntil: "networkidle",
      timeout: 60_000,
    });
    await expect(page.locator(".sb-tab-header")).toBeVisible(); // gotoSingbox readiness
    await use(page);
  },
});

export { expect };

// Pass-1 zero-churn shims (keep spec bodies near-identical)
export function assert(label: string, cond: unknown, extra?: unknown): void {
  expect(
    cond,
    extra !== undefined ? `${label}: ${JSON.stringify(extra)}` : label,
  ).toBeTruthy();
}
export const wait = (ms: number) => new Promise((r) => setTimeout(r, ms));

// === Helpers ported VERBATIM from _setup.mjs (page.evaluate bodies unchanged). ===
// D3 edits applied:
//   gotoSingbox:        absorbed into the `page` fixture above (not exported standalone).
//                       grep: only used in _setup.mjs internally (runTest), not in specs.
//   fetchPreviewConfig: `await page.cookies()` -> `await page.context().cookies()`.

// Execute a shell command inside the test container and return stdout. The
// container exposes BusyBox + uci/ubus/nft/logread; this is the seam tests
// use to seed UCI fixtures and probe runtime state.
//
// containerExec runs a shell command inside the test container via
// `docker exec -i ... sh`. The command is piped on stdin so we don't have
// to quote-escape anything. Synchronous — blocks the event loop for the
// duration; that's fine for short UCI seed/cleanup commands but use with
// care for anything that sleeps or waits.
export function containerExec(cmd: string): string {
  if (!DOCKER_NAME)
    throw new Error("containerExec: DOCKER_NAME env var not set");
  return execSync(`docker exec -i ${DOCKER_NAME} sh`, {
    input: cmd,
    encoding: "utf8",
    stdio: ["pipe", "pipe", "inherit"],
  });
}

export async function openEditModalBySid(
  page: import("@playwright/test").Page,
  kind: string,
  sid: string,
): Promise<void> {
  const opened = await page.evaluate(
    ({ kind, sid }) => {
      const row = document.querySelector(
        `#cbi-singbox-ui-${kind} tr[data-sid="${sid}"]`,
      );
      if (!row) return { ok: false as const, reason: `no row for sid=${sid}` };
      const btn = Array.from(row.querySelectorAll("button")).find((b) =>
        /edit/i.test(b.textContent || ""),
      );
      if (!btn) return { ok: false as const, reason: "no Edit button" };
      btn.click();
      return { ok: true as const };
    },
    { kind, sid },
  );
  if (!opened.ok) throw new Error(`openEditModal: ${opened.reason}`);
  await wait(3500);
}

// Switch the in-modal `protocol` (inbound) or `type` (outbound) dropdown.
// Required because most descriptor fields depend on the discriminator and
// won't surface until it carries the right value.
export async function setProtocolInModal(
  page: import("@playwright/test").Page,
  value: string,
  fieldLabel = "Protocol",
): Promise<void> {
  await page.evaluate(
    ({ value, fieldLabel }) => {
      const ov = document.getElementById("modal_overlay") as HTMLElement;
      const row = Array.from(ov.querySelectorAll(".cbi-value")).find(
        (r) =>
          (r.querySelector(".cbi-value-title") || ({} as Element))
            .textContent === fieldLabel,
      );
      if (!row) throw new Error(`no "${fieldLabel}" dropdown in modal`);
      const sel = row.querySelector("select");
      if (!sel) throw new Error(`"${fieldLabel}" row has no <select>`);
      sel.value = value;
      sel.dispatchEvent(new Event("change", { bubbles: true }));
    },
    { value, fieldLabel },
  );
  await wait(800);
}

// Click the <a> inside a tab <li> by data-tab name. LuCI's switchTab
// listens on the anchor, not the li.
export async function clickTab(
  page: import("@playwright/test").Page,
  tabName: string,
): Promise<void> {
  const r = await page.evaluate((tabName) => {
    const ov = document.getElementById("modal_overlay") as HTMLElement;
    const li = ov.querySelector(
      `.cbi-tabmenu > li[data-tab="${tabName}"]`,
    ) as HTMLElement | null;
    if (!li) return { ok: false, reason: "no tab li" };
    if (li.style.display === "none")
      return { ok: false, reason: "tab hidden (empty)" };
    const a = li.querySelector("a");
    if (a) a.click();
    return { ok: true };
  }, tabName);
  if (!r.ok) throw new Error(`clickTab("${tabName}"): ${r.reason}`);
  await wait(400);
}

// Returns the list of visible (CSS display !== none) `<label class="cbi-value-title">`
// captions in the currently-active modal tab.
export async function visibleFieldsInActiveTab(
  page: import("@playwright/test").Page,
): Promise<string[]> {
  return page.evaluate(() => {
    const ov = document.getElementById("modal_overlay") as HTMLElement;
    const activePane =
      ov.querySelector('[data-tab][data-tab-active="true"]') || ov;
    return Array.from(activePane.querySelectorAll(".cbi-value"))
      .filter((v) => getComputedStyle(v).display !== "none")
      .map(
        (v) =>
          (v.querySelector(".cbi-value-title") as Element | null)
            ?.textContent || null,
      )
      .filter((x): x is string => Boolean(x));
  });
}

// Currently-active tab name and the list of all tab li metadata.
export async function listTabs(
  page: import("@playwright/test").Page,
): Promise<
  Array<{ name: string | null; text: string; active: boolean; hidden: boolean }>
> {
  return page.evaluate(() => {
    const ov = document.getElementById("modal_overlay") as HTMLElement;
    return Array.from(ov.querySelectorAll(".cbi-tabmenu > li")).map((li) => ({
      name: li.getAttribute("data-tab"),
      text: (li.textContent || "").trim(),
      active: li.classList.contains("cbi-tab"),
      hidden: (li as HTMLElement).style.display === "none",
    }));
  });
}

// Dismiss the open modal.
export async function dismissModal(
  page: import("@playwright/test").Page,
): Promise<void> {
  await page.evaluate(() => {
    const ov = document.getElementById("modal_overlay");
    const btn =
      ov &&
      Array.from(ov.querySelectorAll("button")).find((b) =>
        /dismiss|cancel|close/i.test(b.textContent || ""),
      );
    if (btn) btn.click();
  });
  await wait(500);
}

// Toggle the "Show advanced fields" virtual flag in the currently-active tab.
// Bug 4: inbound/outbound builders no longer carry this toggle — all fields are
// shown immediately. When the row is absent we no-op, so callers that toggle
// then assert an (already-visible) advanced field still pass. DNS/Route keep the
// toggle, where this still clicks it.
export async function toggleAdvanced(
  page: import("@playwright/test").Page,
): Promise<void> {
  await page.evaluate(() => {
    const ov = document.getElementById("modal_overlay") as HTMLElement;
    const activePane =
      ov.querySelector('[data-tab][data-tab-active="true"]') || ov;
    const row = Array.from(activePane.querySelectorAll(".cbi-value")).find(
      (r) =>
        /show advanced fields/i.test(
          (r.querySelector(".cbi-value-title") as Element | null)
            ?.textContent || "",
        ),
    );
    if (!row) return; // no advanced toggle (inbound/outbound) — fields already visible
    // LuCI Flag widget: hidden input + a button-like label.
    const checkbox = row.querySelector(
      'input[type="checkbox"]',
    ) as HTMLInputElement | null;
    if (checkbox) {
      checkbox.click(); // toggles via real click event; triggers depends
      return;
    }
    const btn = row.querySelector("button, label");
    if (btn) {
      (btn as HTMLElement).click();
      return;
    }
    throw new Error("no toggleable element in Show advanced row");
  });
  await wait(500);
}

// Click "Add" in the kind table and wait for the modal.
// kind: 'inbound' or 'outbound'.
// name: required — LuCI's GridSection won't enable the Add button until
//       `.cbi-section-create-name` is filled with a valid UCI section
//       name. The helper fills it, fires the input+blur events the
//       uciname validator listens on, then clicks Add.
export async function openAddModal(
  page: import("@playwright/test").Page,
  kind: string,
  name: string,
): Promise<void> {
  if (!name || typeof name !== "string") {
    throw new Error(`openAddModal: name is required (kind=${kind})`);
  }
  const opened = await page.evaluate(
    ({ kind, name }) => {
      const tbl = document.getElementById(`cbi-singbox-ui-${kind}`);
      if (!tbl)
        return { ok: false as const, reason: `no #cbi-singbox-ui-${kind}` };

      // LuCI renders a .cbi-section-create row INSIDE the GridSection div
      // (#cbi-singbox-ui-<kind> is the .cbi-section element itself). Query
      // WITHIN that element first — when several grids share one Map (DNS:
      // dns_server + dns_rule + settings under one cbi-map), a parentElement
      // query would grab the first grid's create-name and open the WRONG
      // modal. Scoped-within is correct for every grid (verified inbound/
      // outbound/dns_server/dns_rule). Fall back to the looser lookups only
      // if the section-scoped one is somehow absent.
      const nameInp = (tbl.querySelector(".cbi-section-create-name") ||
        (tbl.parentElement as HTMLElement).querySelector(
          ".cbi-section-create-name",
        ) ||
        document.querySelector(
          `#cbi-singbox-ui-${kind} ~ .cbi-section-create .cbi-section-create-name`,
        ) ||
        document.querySelector(
          ".cbi-section-create-name",
        )) as HTMLInputElement | null;
      if (!nameInp)
        return {
          ok: false as const,
          reason: "no .cbi-section-create-name input",
        };

      nameInp.focus();
      nameInp.value = name;
      nameInp.dispatchEvent(new Event("input", { bubbles: true }));
      nameInp.dispatchEvent(new Event("blur", { bubbles: true }));
      nameInp.dispatchEvent(new Event("change", { bubbles: true }));

      const addBtn = (nameInp
        .closest(".cbi-section-create")
        ?.querySelector(".cbi-button-add") ||
        document.querySelector(
          ".cbi-section-create .cbi-button-add",
        )) as HTMLButtonElement | null;
      if (!addBtn)
        return { ok: false as const, reason: "no Add button in create row" };

      // The validator may still be racing; force-enable defensively.
      addBtn.disabled = false;
      addBtn.click();
      return { ok: true as const };
    },
    { kind, name },
  );

  if (!opened.ok) throw new Error(`openAddModal: ${opened.reason}`);
  await wait(3500);
}

// Click a TOP-LEVEL view tab (data-tab on .sb-tab-header > li). Unlike
// clickTab(), this is NOT inside #modal_overlay — it switches the whole-page
// tab wired by main.js render(). Returns true on success.
export async function clickTopTab(
  page: import("@playwright/test").Page,
  dataTab: string,
): Promise<boolean> {
  const ok = await page.evaluate((dataTab) => {
    const li = document.querySelector(
      `.sb-tab-header > li[data-tab="${dataTab}"]`,
    );
    if (!li) return false;
    const a = li.querySelector("a") || li;
    (a as HTMLElement).click();
    return true;
  }, dataTab);
  await wait(800); // let the dashboard/monitoring start()/stop() hooks settle
  return ok;
}

// Click a Route sub-tab (.sb-subtab-header > li[data-tab=routerules|rulesets|routedef]).
export async function clickSubTab(
  page: import("@playwright/test").Page,
  dataTab: string,
): Promise<boolean> {
  const ok = await page.evaluate((dataTab) => {
    const li = document.querySelector(
      `.sb-subtab-header > li[data-tab="${dataTab}"]`,
    );
    if (!li) return false;
    const a = li.querySelector("a") || li;
    (a as HTMLElement).click();
    return true;
  }, dataTab);
  await wait(400);
  return ok;
}

// Node-side: parse one .mjs source string for `export const COVERS = [ ... ]`
// and return the array of string ids (or [] if none). Tolerant of single/double
// quotes and newlines. Shared by the ui-surface guard and run-all bookkeeping.
export function extractCovers(src: string): string[] {
  const m = src.match(/export\s+const\s+COVERS\s*=\s*\[([\s\S]*?)\]/);
  if (!m) return [];
  return Array.from(m[1].matchAll(/['"]([^'"]+)['"]/g)).map((x) => x[1]);
}

// Fill a labeled field in the currently-open modal. opts.kind selects
// the writer: 'flag' clicks a checkbox; 'select' sets value+dispatches
// change; 'text'/'number' (default) writes to input.value+input event.
//
// Caller must clickTab() into the right tab first — when two tabs use
// the same .cbi-value-title text (e.g., "Tag" on Inbound and Inbound‑TLS),
// the first DOM match wins regardless of visibility.
export async function fillField(
  page: import("@playwright/test").Page,
  label: string,
  value: unknown,
  opts: { kind?: string } = {},
): Promise<void> {
  const kind = opts.kind || "text";
  const r = await page.evaluate(
    ({ label, value, kind }) => {
      const ov = document.getElementById("modal_overlay") as HTMLElement;
      const row = Array.from(ov.querySelectorAll(".cbi-value")).find(
        (r) =>
          (
            (r.querySelector(".cbi-value-title") as Element | null)
              ?.textContent || ""
          ).trim() === label,
      );
      if (!row) return { ok: false, reason: `no row "${label}"` };
      if (kind === "flag") {
        const cb = row.querySelector(
          'input[type="checkbox"]',
        ) as HTMLInputElement | null;
        if (!cb) return { ok: false, reason: `"${label}" no checkbox` };
        if (Boolean(cb.checked) !== Boolean(Number(value))) cb.click();
        return { ok: true };
      }
      if (kind === "select") {
        const sel = row.querySelector("select") as HTMLSelectElement | null;
        if (!sel) return { ok: false, reason: `"${label}" no select` };
        sel.value = String(value);
        sel.dispatchEvent(new Event("change", { bubbles: true }));
        return { ok: true };
      }
      const inp = row.querySelector(
        'input[type="text"], input[type="number"], input[type="password"], input:not([type])',
      ) as HTMLInputElement | null;
      if (!inp) return { ok: false, reason: `"${label}" no input` };
      inp.focus();
      inp.value = String(value);
      inp.dispatchEvent(new Event("input", { bubbles: true }));
      inp.dispatchEvent(new Event("change", { bubbles: true }));
      return { ok: true };
    },
    { label, value, kind },
  );
  if (!r.ok) throw new Error(`fillField("${label}"): ${r.reason}`);
  await wait(300);
}

// Click modal Save (which queues UCI changes into LuCI's in-memory uci
// store), then directly call L.uci.save() to flush to disk via rpcd.
// Apply (which triggers sing-box restart) is intentionally skipped — the
// test container's /etc/init.d/sing-box is a stub, and we only want the
// UCI write so preview_config sees the new section.
//
// Empirical: clicking the action-bar "Save" button spins indefinitely
// because the modal stays open (the modal Save handler queues changes
// but LuCI's GridSection re-renders the create row without closing the
// modal_overlay). Calling L.uci.save() directly is the canonical API
// path and bypasses the button-state racing entirely.
export async function saveAndReload(
  page: import("@playwright/test").Page,
): Promise<void> {
  // Modal Save — positive button. Queues changes into L.uci (in-memory).
  await page.evaluate(() => {
    const ov = document.getElementById("modal_overlay");
    const btn = ov?.querySelector("button.cbi-button-positive");
    if (!btn) throw new Error("no modal Save (cbi-button-positive) button");
    (btn as HTMLButtonElement).click();
  });
  await wait(2000); // let the modal's async handler queue all field writes
  // Flush queued UCI changes via the rpcd write path. L.uci.save() pushes
  // pending in-memory changes to rpcd; L.uci.apply(0) finalises them on
  // disk WITHOUT triggering the apply-confirm dialog (timeout=0). The
  // stubbed /etc/init.d/sing-box swallows the post-write restart hook.
  const res = await page.evaluate(async () => {
    if (!window.L || !L.uci) return { err: "no L.uci" };
    try {
      await L.uci.save();
      // apply() may reject when the rollback timer expires — that's
      // fine; the on-disk commit already happened. Swallow.
      try {
        await L.uci.apply(0);
      } catch (_) {}
      return { ok: true };
    } catch (e) {
      return { err: String(e) };
    }
  });
  if (res?.err) throw new Error(`saveAndReload: ${res.err}`);
  // Give rpcd a moment to flush; preview_config retries 3× anyway.
  await wait(1200);
}

// Call the singbox-ui preview_config RPC from the page context, parse
// the `content` field as JSON, return the object. Retries 3× on
// transient errors (rpcd settling after UCI rewrite); backoff schedule
// 200/500/1250 ms covers ~1.95 s of rpcd reload jitter.
//
// The sysauth_http cookie is HttpOnly (newPage sets it that way to
// mirror how LuCI itself sets it). page.evaluate runs in the page
// context which cannot read HttpOnly cookies, so we extract the token
// node-side via Playwright's cookies API and pass it into evaluate.
// D3 edit: `await page.cookies()` -> `await page.context().cookies()`.
export async function fetchPreviewConfig(
  page: import("@playwright/test").Page,
): Promise<unknown> {
  const cookies = await page.context().cookies();
  const tokenCookie = cookies.find((c) => c.name === "sysauth_http");
  if (!tokenCookie) throw new Error("no sysauth_http cookie");
  const token = tokenCookie.value;

  for (let attempt = 0, delay = 200; attempt < 3; attempt++, delay *= 2.5) {
    try {
      const result = await page.evaluate(async (token) => {
        const r = await fetch("/cgi-bin/luci/admin/ubus", {
          method: "POST",
          headers: { "content-type": "application/json" },
          body: JSON.stringify({
            jsonrpc: "2.0",
            id: 1,
            method: "call",
            params: [token, "singbox-ui", "preview_config", {}],
          }),
        });
        const j = await r.json();
        if (j.error) throw new Error(`ubus error: ${JSON.stringify(j.error)}`);
        const payload = j.result?.[1];
        // preview_config emits { status: "ok", content: "<json>" } on
        // success; some older paths used "success" — accept both.
        const okStatus =
          payload && (payload.status === "ok" || payload.status === "success");
        if (!okStatus || !payload.content)
          throw new Error(
            "bad preview_config payload: " +
              JSON.stringify(payload).slice(0, 200),
          );
        return payload.content;
      }, token);
      return JSON.parse(result as string);
    } catch (e) {
      if (attempt === 2) throw e;
      await wait(delay);
    }
  }
}
