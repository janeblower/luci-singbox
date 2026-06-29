// LuCI client-runtime globals used inside page.evaluate() bodies.
// Typed as `any` — these execute in the browser, not under tsc's Node view.
declare const L: any;

// window.L is accessed in saveAndReload's evaluate body.
interface Window {
  L: any;
}
