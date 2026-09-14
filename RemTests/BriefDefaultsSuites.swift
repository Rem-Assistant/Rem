import Testing

/// Parent suite for every test that swaps the process-global `BriefContext.defaults`.
///
/// `@Suite(.serialized)` serializes tests WITHIN a suite; sibling suites still run in parallel.
/// `BriefContextTests` and `BriefHeadlineTests` both point that static at their own isolated
/// `UserDefaults` for the duration of the suite, so running them as siblings let one suite's
/// init/deinit re-point the store between another suite's write and read — a write landed in one
/// store and the read came back empty. Nesting them under one serialized parent is what actually
/// makes the swap safe; it is not cosmetic.
///
/// Any future suite that assigns `BriefContext.defaults` belongs in here too.
@Suite(.serialized)
struct BriefDefaultsSuites {}
