import { readFileSync } from "node:fs";
import { resolve } from "node:path";
import vm from "node:vm";
import { describe, expect, it } from "vitest";

// requires_pkg: a field (kTLS -> kmod-tls, tun auto_redirect -> kmod-nft-queue)
// renders an inline note with a one-click Install button — but ONLY while the
// package is actually missing. Once it is installed the note says nothing the
// operator needs, so it stays hidden entirely. A failed probe counts as
// installed (fail-open): otherwise every rpcd hiccup nags the user to install
// something they already have.

const DESCRIPTOR_FORM_JS = resolve(
  import.meta.dirname,
  "../../luci-app-singbox-ui/htdocs/luci-static/resources/view/singbox-ui/lib/descriptor_form.js",
);

// Minimal DOM: only the API attachPkgNote touches (appendChild/removeChild,
// textContent, click handler).
function el(tag: string, attrs: any, children: any) {
  const node: any = {
    tag,
    attrs: attrs || {},
    children: [] as any[],
    textContent: "",
    disabled: false,
    // Enough of CSSStyleDeclaration for the show/hide the note does. The inline
    // `style` attribute is the only way E() can set it at construction.
    style: {
      display: /display\s*:\s*none/.test(String((attrs || {}).style || ""))
        ? "none"
        : "",
    },
    appendChild(c: any) {
      c.parentNode = node;
      node.children.push(c);
      return c;
    },
    removeChild(c: any) {
      node.children = node.children.filter((x: any) => x !== c);
      return c;
    },
  };
  if (typeof children === "string") node.textContent = children;
  else if (Array.isArray(children))
    children.forEach((c) => {
      node.appendChild(c);
    });
  else if (children) node.appendChild(children);
  return node;
}

function loadDF(SbRpc: any) {
  const src = readFileSync(DESCRIPTOR_FORM_JS, "utf8");
  const body = src
    .replace(/^'use strict';\s*/, "")
    .replace(/^'require [^']+';\s*/gm, "")
    .replace(
      /return L\.Class\.extend\((\{[\s\S]*\})\);?\s*$/,
      "__moduleExports = $1;",
    );
  const sandbox: Record<string, unknown> = {
    __moduleExports: null,
    _: (s: unknown) => s,
    L: { Class: { extend: (o: unknown) => o } },
    E: el,
    document: { createTextNode: (t: string) => el("#text", {}, t) },
    ui: { addNotification: () => {} },
    form: {},
    network: {},
    uci: {},
    validators: {},
    SbViewState: {},
    SbCommon: {},
    SbRpc,
    Promise,
    console,
  };
  vm.createContext(sandbox);
  vm.runInContext(
    "if(!String.prototype.format){Object.defineProperty(String.prototype,'format',{value:function(){var a=arguments,i=0;return String(this).replace(/%[sd]/g,function(){return String(a[i++]);});}});}",
    sandbox,
  );
  vm.runInContext(`(function(){${body}})();`, sandbox, {
    filename: "descriptor_form.js",
  });
  return (sandbox as any).__moduleExports;
}

function render(DF: any, pkg = "kmod-tls") {
  const widget = el("div", {}, null);
  const opt: any = { renderWidget: () => widget };
  DF.attachPkgNote(opt, pkg);
  return { widget, node: opt.renderWidget("sid", 0, "0") };
}

const flush = () => new Promise((r) => setTimeout(r, 0));

describe("descriptor_form.js — requires_pkg note", () => {
  it("missing package: note + Install button, click installs and drops the button", async () => {
    let installed: string | null = null;
    const DF = loadDF({
      callPkgStatus: () => Promise.resolve({ installed: false }),
      callPkgInstall: (p: string) => {
        installed = p;
        return Promise.resolve({ status: "ok" });
      },
    });
    const { widget } = render(DF);
    await flush();

    const note = widget.children[0];
    expect(note.attrs.class).toBe("cbi-value-description");
    expect(note.style.display).toBe(""); // revealed: the package is absent
    expect(note.textContent).toContain("kmod-tls");
    const btn = note.children.find((c: any) => c.tag === "button");
    expect(btn).toBeTruthy();

    btn.attrs.click({ preventDefault: () => {} });
    await flush();
    expect(installed).toBe("kmod-tls");
    expect(note.children.some((c: any) => c.tag === "button")).toBe(false);
  });

  it("installed package: note stays hidden, no button", async () => {
    const DF = loadDF({
      callPkgStatus: () => Promise.resolve({ installed: true }),
      callPkgInstall: () => Promise.reject(new Error("must not be called")),
    });
    const { widget } = render(DF);
    await flush();
    expect(widget.children[0].style.display).toBe("none");
    expect(widget.children[0].children.length).toBe(0);
  });

  it("probe failure is fail-open: note stays hidden, no button", async () => {
    const DF = loadDF({
      callPkgStatus: () => Promise.reject(new Error("rpcd down")),
      callPkgInstall: () => Promise.reject(new Error("must not be called")),
    });
    const { widget } = render(DF);
    await flush();
    expect(widget.children[0].style.display).toBe("none");
    expect(widget.children[0].children.length).toBe(0);
  });

  it("probes the package once per page, not once per field", async () => {
    let probes = 0;
    const DF = loadDF({
      callPkgStatus: () => {
        probes++;
        return Promise.resolve({ installed: true });
      },
    });
    render(DF);
    render(DF);
    await flush();
    expect(probes).toBe(1);
  });
});
