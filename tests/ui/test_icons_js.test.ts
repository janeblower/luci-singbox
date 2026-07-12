import { resolve } from "node:path";
import { describe, expect, it } from "vitest";
import { loadLuciModule } from "../helpers/luci.ts";

// lib/icons.js MUST build nodes with document.createElementNS: LuCI's E() uses
// document.createElement, which yields an HTMLUnknownElement for <svg> and the
// icon never renders. This test fails the moment someone "simplifies" the module
// back onto createElement.

const SVG_NS = "http://www.w3.org/2000/svg";

const ICONS_JS = resolve(
  import.meta.dirname,
  "../../luci-app-singbox-ui/htdocs/luci-static/resources/view/singbox-ui/lib/icons.js",
);

interface FakeEl {
  namespaceURI: string;
  tagName: string;
  attrs: Record<string, string>;
  children: FakeEl[];
  setAttribute(k: string, v: string): void;
  appendChild(c: FakeEl): FakeEl;
}

const { exports: icons } = loadLuciModule(ICONS_JS, {
  Object,
  String,
  document: {
    createElementNS(ns: string, tag: string): FakeEl {
      return {
        namespaceURI: ns,
        tagName: tag,
        attrs: {},
        children: [],
        setAttribute(k, v) {
          this.attrs[k] = v;
        },
        appendChild(c) {
          this.children.push(c);
          return c;
        },
      };
    },
    // Present on purpose: if the module regresses onto createElement, it builds
    // a node in the HTML namespace and the namespaceURI assertions below fail.
    createElement(tag: string): FakeEl {
      return {
        namespaceURI: "http://www.w3.org/1999/xhtml",
        tagName: tag,
        attrs: {},
        children: [],
        setAttribute(k, v) {
          this.attrs[k] = v;
        },
        appendChild(c) {
          this.children.push(c);
          return c;
        },
      };
    },
  },
});

const NAMES = [
  "loaderCircle",
  "copy",
  "info",
  "link",
  "x",
  "pause",
  "play",
  "search",
  "snake",
];

describe("lib/icons.js", () => {
  it.each(NAMES)("%s is exported", (name) => {
    expect(typeof icons[name]).toBe("function");
  });

  it.each(NAMES)("%s root is an <svg> in the SVG namespace", (name) => {
    const el: FakeEl = icons[name]();
    expect(el.tagName).toBe("svg");
    expect(el.namespaceURI).toBe(SVG_NS);
  });

  it.each(NAMES)("%s children are in the SVG namespace too", (name) => {
    const el: FakeEl = icons[name]();
    expect(el.children.length).toBeGreaterThan(0);
    for (const c of el.children) expect(c.namespaceURI).toBe(SVG_NS);
  });

  it("carries the shared stroke attributes", () => {
    const el: FakeEl = icons.copy();
    expect(el.attrs.viewBox).toBe("0 0 24 24");
    expect(el.attrs.fill).toBe("none");
    expect(el.attrs.stroke).toBe("currentColor");
    expect(el.attrs["stroke-width"]).toBe("2");
    expect(el.attrs["stroke-linecap"]).toBe("round");
    expect(el.attrs["stroke-linejoin"]).toBe("round");
  });

  it("does not hardcode width/height (size comes from CSS)", () => {
    const el: FakeEl = icons.info();
    expect(el.attrs.width).toBeUndefined();
    expect(el.attrs.height).toBeUndefined();
  });

  it("loaderCircle spins via the CSS class, not SMIL", () => {
    const el: FakeEl = icons.loaderCircle();
    expect(el.attrs.class).toContain("sb-icon-spin");
    expect(el.children.some((c) => c.tagName === "animateTransform")).toBe(
      false,
    );
  });

  it("snake has no viewBox and a pathLength=100 rect", () => {
    const el: FakeEl = icons.snake();
    expect(el.attrs.class).toBe("sb-snake");
    expect(el.attrs.viewBox).toBeUndefined();
    const rect = el.children[0];
    expect(rect.tagName).toBe("rect");
    expect(rect.attrs.pathLength).toBe("100");
    expect(rect.attrs.width).toBe("100%");
  });
});
