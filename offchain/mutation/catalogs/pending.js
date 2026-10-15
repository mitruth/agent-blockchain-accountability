// Spec 8's mutants whose code does not exist yet. Each moves into a catalogue
// in the step that builds its code; the runner lists them so none is
// forgotten.

export default [
  { name: "<= becomes < on a policy's cap comparison", step: 4, note: "WindowLib's own comparison is in the window catalogue" },
  { name: "expiry counted as cancel in S6", step: 4, note: "the ledger side, expiry reported as a cancellation, is in the ledger catalogue" },
  { name: "reading accepted with a decreasing timestamp", step: 5, note: "OracleVerifier" },
  { name: "H_slots <= k check removed", step: 5, note: "S3, DeliverabilityPolicy configuration" },
  { name: "placed buys credited in the S3 floor", step: 5, note: "S3, DeliverabilityPolicy" },
];
