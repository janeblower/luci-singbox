// Shared CBI form-widget + validator stubs for descriptor_form.js unit tests.
//
// The string-identity `form` map is what applyMaterialized() reads to pick a
// widget class; the tests only need distinct sentinel values (MultiValue must be
// DISTINCT from DynamicList — controlKindFor() tells them apart by identity).
// TextValue is in the superset so multiline fields resolve; files that never
// exercise multiline simply never select it.
//
// Only the string-based tests share these. The dynamic/named/version-gate tests
// need real widget FUNCTIONS/constructors (`.load` prototype, `new W()`), so they
// keep their own `form` stub.
export const formStub: Record<string, string> = {
  Flag: "Flag",
  ListValue: "ListValue",
  DynamicList: "DynamicList",
  MultiValue: "MultiValue",
  Value: "Value",
  TextValue: "TextValue",
};

// No-op validator registry (superset). attachValidator() looks names up here;
// returning true keeps every field valid. Extra keys are harmless.
export const validatorsStub: Record<string, () => boolean> = {
  host: () => true,
  port: () => true,
  uuid: () => true,
  alpn: () => true,
};
