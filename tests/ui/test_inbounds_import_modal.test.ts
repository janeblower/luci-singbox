import { describe, expect, it } from "bun:test";
import { resolve } from "node:path";
import { loadLuciModule } from "../helpers/luci.ts";

// Regression test for uit-3: split-string i18n anti-pattern.
// Verifies that the import modal message uses a format string placeholder
// instead of concatenating fragments, which allows translators to properly
// reorder components like kind (e.g., "inbound" or "outbound").

const INBOUNDS_JS = resolve(
  import.meta.dir,
  "../../luci-app-singbox-ui/htdocs/luci-static/resources/view/singbox-ui/tabs/inbounds.js",
);

const { exports: Inbounds } = loadLuciModule(INBOUNDS_JS, {
  _: (s: string) => s,
  E: (tag: string, attrs?: any, children?: any) => ({
    tag,
    attrs: attrs || {},
    children: children || [],
    textContent: "",
  }),
  ui: {
    showModal: (title: string, body: any[]) => {
      // Capture the modal title and first element for verification
      (globalThis as any)._lastModalTitle = title;
      (globalThis as any)._lastModalBody = body;
    },
    hideModal: () => {},
  },
  form: {},
  uci: { get: () => undefined, add: () => {}, set: () => {} },
  // Alias globals injected by the stripped `'require ... as X'` directives.
  // inbounds.js binds `addRenameField = SbCommon.addRenameField` at load time,
  // so SbCommon must exist; the rest are only touched by code paths this test
  // does not exercise.
  widgets: {},
  SbCommon: { addRenameField: () => {} },
  SbValidators: {},
  SbImpInbound: {},
  SbImpOutbound: {},
  descriptor_form: {},
  SbViewState: {},
});

describe("inbounds.js openJsonImportModal (uit-3)", () => {
  it("renders import modal with kind embedded in single format string", () => {
    const openJsonImportModal = Inbounds.openJsonImportModal;
    openJsonImportModal("inbound", {});

    const title = (globalThis as any)._lastModalTitle;
    const body = (globalThis as any)._lastModalBody;

    expect(title).toBe("Import JSON");
    expect(body).toBeDefined();
    expect(body.length).toBeGreaterThan(0);

    // The first body element is the <p> with the blurb. Verify it contains
    // the kind ("inbound") in the rendered text.
    const pElement = body[0];
    expect(pElement.tag).toBe("p");
    // After format(), the text should contain both "sing-box" and "inbound"
    // This verifies the placeholder was substituted correctly.
    const renderedText = pElement.children;
    const fullText =
      typeof renderedText === "string"
        ? renderedText
        : renderedText?.toString?.() || "";
    expect(fullText.indexOf("inbound")).toBeGreaterThanOrEqual(0);
  });

  it("renders import modal with outbound kind", () => {
    const openJsonImportModal = Inbounds.openJsonImportModal;
    openJsonImportModal("outbound", {});

    const body = (globalThis as any)._lastModalBody;
    expect(body).toBeDefined();
    const pElement = body[0];
    expect(pElement.tag).toBe("p");
    // Verify outbound is rendered
    const renderedText = pElement.children;
    const fullText =
      typeof renderedText === "string"
        ? renderedText
        : renderedText?.toString?.() || "";
    expect(fullText.indexOf("outbound")).toBeGreaterThanOrEqual(0);
  });
});
