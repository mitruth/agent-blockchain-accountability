// Step 3: WindowLib. The window mutants of spec 8, marked (spec 8), and the
// defects specific to this implementation: the ring's packing, the two sweeps,
// each class's own rule, the configuration checks.
//
// Also run against the independent verifier (`verifier: true`): a mutant the
// Solidity tests miss but the verifier catches still counts as caught, and the
// report says which caught it.
//
// `nth` picks one occurrence where a line appears more than once: the
// read-only sweep (_slideView) comes first, the writing sweep (_slide) second.

const W = "contracts/policies/WindowLib.sol";

export default {
  name: "window",
  tests: ["test/policies/WindowLib.t.sol"],
  verifier: true,
  mutants: [
    // --- spec 8 ---
    { name: "cap comparison <= becomes < (spec 8)", file: W,
      find: "return uint256(used(w, t)) + amount <= limit(w, t);",
      replace: "return uint256(used(w, t)) + amount < limit(w, t);" },
    { name: "bucket index off by one (spec 8)", file: W,
      find: "uint256 index = (t / c.step) % c.buckets;",
      replace: "uint256 index = (t / c.step + 1) % c.buckets;" },
    { name: "window start shifted one bucket later, read (spec 8)", file: W, nth: 1,
      find: "uint256 k = mark + 1;", replace: "uint256 k = mark + 2;" },
    { name: "window start shifted one bucket later, write (spec 8)", file: W, nth: 2,
      find: "uint256 k = mark + 1;", replace: "uint256 k = mark + 2;" },
    { name: "window start shifted one bucket earlier, read (spec 8)", file: W, nth: 1,
      find: "uint256 k = mark + 1;", replace: "uint256 k = mark;" },
    { name: "window start shifted one bucket earlier, write (spec 8)", file: W, nth: 2,
      find: "uint256 k = mark + 1;", replace: "uint256 k = mark;" },
    { name: "credit to the current bucket instead of the original (spec 8)", file: W,
      find: "uint256 bucket = placedAt / c.step;", replace: "uint256 bucket = t / c.step;" },
    { name: "credit applied outside the window (spec 8)", file: W,
      find: "if (t / c.step - bucket >= c.buckets) return 0;", replace: "" },
    { name: "credit applied one bucket beyond the window (spec 8)", file: W,
      find: "if (t / c.step - bucket >= c.buckets) return 0;", replace: "if (t / c.step - bucket > c.buckets) return 0;" },
    { name: "generation not bumped on full reset (spec 8)", file: W,
      find: "// Lazy reset: every bucket left the window. O(1), whatever n.\n                w.generation += 1;",
      replace: "// Lazy reset: every bucket left the window. O(1), whatever n." },

    // --- the ring and the sweeps ---
    { name: "restart does not bump the generation", file: W,
      find: "        w.generation += 1;\n        w.count = 0;", replace: "        w.count = 0;" },
    { name: "the writing sweep does not clear what expired", file: W,
      find: "            w.ring[generation][wordIndex] = word;\n", replace: "" },
    { name: "the read-only sweep reads the wrong storage word", file: W,
      find: "uint256 word = w.ring[generation][index >> 2];", replace: "uint256 word = w.ring[generation][index >> 1];" },
    { name: "a lane is read from the wrong position", file: W,
      find: "return uint64((word >> ((index & 3) * LANE_BITS)) & LANE_MASK);",
      replace: "return uint64((word >> ((index & 1) * LANE_BITS)) & LANE_MASK);" },
    { name: "writing a lane does not clear its old value", file: W,
      find: "words[index >> 2] = (words[index >> 2] & ~(LANE_MASK << shift)) | (uint256(value) << shift);",
      replace: "words[index >> 2] = words[index >> 2] | (uint256(value) << shift);" },
    { name: "sliding mark not advanced on write", file: W,
      find: "if (bucket > w.mark) w.mark = uint64(bucket);", replace: "" },

    // --- credits ---
    { name: "a credit may take a bucket below zero", file: W,
      find: "credited = amount < lane ? amount : lane;", replace: "credited = amount;" },
    { name: "a credit dated in the future is accepted", file: W,
      find: "if (placedAt > t) return 0;", replace: "" },

    // --- TUMBLING ---
    { name: "tumbling never restarts", file: W,
      find: "if (period != w.mark) {", replace: "if (false) {" },
    { name: "tumbling count read without its period", file: W,
      find: "if (c.kind == Kind.TUMBLING) return _period(c, t) == w.mark ? w.count : 0;",
      replace: "if (c.kind == Kind.TUMBLING) return w.count;" },
    { name: "tumbling credit across periods", file: W,
      find: "if (c.kind == Kind.TUMBLING && _period(c, placedAt) != w.mark) return 0;", replace: "" },
    { name: "tumbling periods anchored at zero, not at the anchor", file: W,
      find: "return t > c.anchor ? (t - c.anchor) / c.step : 0;", replace: "return t / c.step;" },

    // --- REFILL ---
    { name: "refill credit across intervals: the double refund", file: W,
      find: "if (c.kind == Kind.REFILL && placedAt / c.step != w.mark) return 0;", replace: "" },
    { name: "refill one interval late", file: W,
      find: "uint256 back = (interval - mark) * uint256(c.rate);", replace: "uint256 back = (interval - mark - 1) * uint256(c.rate);" },
    { name: "refill count read without the refills since", file: W,
      find: "if (c.kind == Kind.REFILL) return _refilled(w.count, c, w.mark, t);", replace: "if (c.kind == Kind.REFILL) return w.count;" },
    { name: "refill mark not advanced: refills counted twice", file: W,
      find: "if (interval > w.mark) w.mark = uint64(interval);", replace: "" },

    // --- STREAM ---
    { name: "stream not capped", file: W,
      find: "return unlocked < c.cap ? uint64(unlocked) : c.cap;", replace: "return uint64(unlocked);" },
    { name: "stream unlocks one interval early", file: W,
      find: "uint256 intervals = t > c.anchor ? (t - c.anchor) / c.step : 0;",
      replace: "uint256 intervals = t > c.anchor ? (t - c.anchor) / c.step + 1 : 0;" },
    { name: "every class limited as a stream", file: W,
      find: "if (c.kind != Kind.STREAM) return c.cap;", replace: "if (c.kind == Kind.LIFETIME) return c.cap;" },

    // --- counting and configuration ---
    { name: "a count beyond 64 bits wraps", file: W,
      find: "if (next > type(uint64).max) revert WindowLib_Overflow();", replace: "" },
    { name: "a change of shape keeps the count", file: W,
      find: "if (!sameShape) _restart(w);", replace: "" },
    { name: "the bucket count is not part of the shape", file: W,
      find: "old.kind == c.kind && old.step == c.step && old.buckets == c.buckets && old.anchor == c.anchor",
      replace: "old.kind == c.kind && old.step == c.step && old.anchor == c.anchor" },
    { name: "the most buckets allowed is exclusive", file: W,
      find: "c.buckets <= MAX_BUCKETS", replace: "c.buckets < MAX_BUCKETS" },
    { name: "zero buckets accepted", file: W,
      find: "return c.step != 0 && c.buckets != 0 && c.buckets <= MAX_BUCKETS;",
      replace: "return c.step != 0 && c.buckets <= MAX_BUCKETS;" },
    { name: "a stream starting above its cap accepted", file: W,
      find: "return c.step != 0 && c.initial <= c.cap;", replace: "return c.step != 0;" },
  ],
};
