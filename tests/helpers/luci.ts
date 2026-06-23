import { readFileSync } from "node:fs";
import vm from "node:vm";

export interface LuciModule {
  exports: any;
  warnings: string[];
}

// LuCI view modules are fragments: `'use strict'; 'require luci.dsl'; ...
// return L.Class.extend({...});`. They are not ES/CommonJS modules, so we
// strip the fragment header, rewrite the trailing `return L.Class.extend({...})`
// into an assignment, and eval in a sandbox to capture the exported namespace.
export function loadLuciModule(
  absPath: string,
  sandboxExtras: Record<string, unknown> = {},
): LuciModule {
  const src = readFileSync(absPath, "utf8");
  const body = src
    .replace(/^'use strict';\s*/, "")
    .replace(/^'require [^']+';\s*/gm, "")
    .replace(
      /return L\.Class\.extend\((\{[\s\S]*\})\);?\s*$/,
      "__moduleExports = $1;",
    );

  const warnings: string[] = [];
  const sandbox: Record<string, unknown> = {
    __moduleExports: undefined,
    console: {
      log: () => {},
      error: () => {},
      warn: (msg: unknown) => warnings.push(String(msg)),
    },
    L: { Class: { extend: (o: unknown) => o } },
    ...sandboxExtras,
  };

  vm.createContext(sandbox);
  // LuCI provides String.prototype.format at runtime; the sandbox's own String
  // intrinsic does not, so inject it (guarded) for modules that call `.format()`.
  vm.runInContext(
    "if(!String.prototype.format){Object.defineProperty(String.prototype,'format',{value:function(){var a=arguments,i=0;return String(this).replace(/%[sd]/g,function(){return String(a[i++]);});},enumerable:false});}",
    sandbox,
  );
  vm.runInContext(body, sandbox, { filename: absPath });
  return { exports: sandbox.__moduleExports, warnings };
}
