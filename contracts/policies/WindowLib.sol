// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

/// @title WindowLib
/// @notice A quantity counted over time, for the sequence policies S1, S2, S4
///         and S6 (spec 5.3). Five ways of counting, one interface:
///
///   used(t)   how much has been consumed, as the window sees it at time t
///   limit(t)  how much the window allows at time t
///   fits      used(t) + amount <= limit(t)
///   add       consume `amount` at time t
///   credit    give back `amount` consumed at `placedAt`, if the window still
///             counts it; returns what was given back
///
/// The classes, and what the fields of `Config` mean for each:
///
///   SLIDING   the last `buckets` buckets of `step` seconds: window W = n * b.
///             limit = cap. A ring of n buckets and a running total.
///   TUMBLING  periods of `step` seconds from `anchor`; the count restarts at
///             each period boundary. limit = cap.
///   REFILL    a token bucket: `rate` comes back every `step` seconds, up to
///             `cap`. used = cap - balance; limit = cap.
///   STREAM    an allowance unlocking from `anchor`: `initial`, plus `rate`
///             every `step` seconds, at most `cap`. used = everything
///             consumed; limit = what has unlocked.
///   LIFETIME  a counter that never resets. limit = cap.
///
/// SLIDING is what the policies use; the other four are the baselines the
/// evaluation runs the same attacks against.
///
/// Time is passed in, normally `block.timestamp`, so that a policy evaluates
/// a check and a commit at the same instant. Bucket index c = t / step, in
/// UTC seconds since 1970.
///
/// Guarantees of SLIDING, for the paper (spec 5.3):
///   - any interval of length <= W - b admits at most the cap;
///   - an interval of exactly W can span n + 1 buckets, so it admits at most
///     the cap plus one bucket's content;
///   - TUMBLING, by contrast, admits 2 x cap within an arbitrarily short
///     interval around a period boundary.
///
/// Sums only: a window adds and credits amounts. A mean is two windows, a
/// ratio of sums is two windows (spec 5.3, allowed aggregates).
library WindowLib {
    enum Kind {
        SLIDING,
        TUMBLING,
        REFILL,
        STREAM,
        LIFETIME
    }

    struct Config {
        Kind kind;
        /// @dev SLIDING: bucket length b. TUMBLING: period length.
        ///      REFILL, STREAM: the interval at which `rate` is added.
        ///      Seconds. Unused by LIFETIME.
        uint32 step;
        /// @dev SLIDING only: the number of buckets n; the window is n * step.
        uint16 buckets;
        /// @dev TUMBLING: start of the first period. STREAM: start of the
        ///      unlocking. Seconds. Before it, TUMBLING counts into the first
        ///      period and STREAM has unlocked `initial` only.
        uint40 anchor;
        /// @dev The hard bound: SLIDING, TUMBLING, LIFETIME the limit itself;
        ///      REFILL the bucket's capacity; STREAM the most that ever unlocks.
        uint64 cap;
        /// @dev REFILL: given back per `step`. STREAM: unlocked per `step`.
        uint64 rate;
        /// @dev STREAM: unlocked at `anchor`.
        uint64 initial;
    }

    /// @dev One window's state. `ring` is keyed by generation: bumping the
    ///      generation makes every bucket of the old one unreachable, so a
    ///      stale storage word reads as zero without being cleared.
    struct Window {
        Config config;
        /// @dev What has been consumed, net of credits. SLIDING: the running
        ///      total of the ring as of bucket `mark`.
        ///      TUMBLING: the total of period `mark`. REFILL: cap - balance as
        ///      of interval `mark`. STREAM, LIFETIME: everything consumed.
        uint64 count;
        /// @dev SLIDING: the last bucket the ring was advanced to.
        ///      TUMBLING: the period `count` belongs to.
        ///      REFILL: the last interval refilled up to.
        uint64 mark;
        uint64 generation;
        mapping(uint256 generation => mapping(uint256 word => uint256)) ring;
    }

    /// @notice The most buckets a sliding window may have. Advancing the ring
    ///         costs at most one step per bucket, so this bounds the gas of
    ///         any call: 2016 buckets is a week of 5-minute buckets.
    uint16 internal constant MAX_BUCKETS = 2016;

    uint256 private constant LANE_BITS = 64;
    uint256 private constant LANE_MASK = type(uint64).max;

    error WindowLib_InvalidConfig();
    error WindowLib_Overflow();

    // ------------------------------------------------------------------
    // Configuration
    // ------------------------------------------------------------------

    /// @notice Whether `c` is a well-formed configuration.
    function isValid(Config memory c) internal pure returns (bool) {
        if (c.kind == Kind.SLIDING) return c.step != 0 && c.buckets != 0 && c.buckets <= MAX_BUCKETS;
        if (c.kind == Kind.TUMBLING) return c.step != 0;
        if (c.kind == Kind.REFILL) return c.step != 0;
        if (c.kind == Kind.STREAM) return c.step != 0 && c.initial <= c.cap;
        return true; // LIFETIME
    }

    /// @notice Set the window's configuration. A change of shape (class,
    ///         step, buckets or anchor) starts the window afresh; a change of
    ///         cap, rate or initial keeps what has been counted.
    /// @dev Starting afresh forgets consumption, so it loosens the window: the
    ///      policy must classify such a change as WIDEN (spec 5.6).
    function configure(Window storage w, Config memory c) internal {
        if (!isValid(c)) revert WindowLib_InvalidConfig();
        Config storage old = w.config;
        bool sameShape =
            old.kind == c.kind && old.step == c.step && old.buckets == c.buckets && old.anchor == c.anchor;
        if (!sameShape) _restart(w);
        w.config = c;
    }

    /// @notice Forget everything counted. The configuration stays.
    function clear(Window storage w) internal {
        _restart(w);
    }

    // ------------------------------------------------------------------
    // Reading
    // ------------------------------------------------------------------

    /// @notice What the window counts as consumed at time `t`.
    function used(Window storage w, uint256 t) internal view returns (uint64) {
        Config memory c = w.config;
        if (c.kind == Kind.SLIDING) {
            (uint256 total,) = _slideView(w, c, t);
            return uint64(total);
        }
        if (c.kind == Kind.TUMBLING) return _period(c, t) == w.mark ? w.count : 0;
        if (c.kind == Kind.REFILL) return _refilled(w.count, c, w.mark, t);
        return w.count; // STREAM, LIFETIME
    }

    /// @notice What the window allows at time `t`.
    function limit(Window storage w, uint256 t) internal view returns (uint64) {
        Config memory c = w.config;
        if (c.kind != Kind.STREAM) return c.cap;
        uint256 intervals = t > c.anchor ? (t - c.anchor) / c.step : 0;
        uint256 unlocked = uint256(c.initial) + intervals * c.rate;
        return unlocked < c.cap ? uint64(unlocked) : c.cap;
    }

    /// @notice A sliding window's total at time `t`, recomputed from its
    ///         buckets one by one instead of from the running total: the
    ///         buckets c - n + 1 ... c that the ring still holds. O(n); for
    ///         tests and audits, not for policies. Other classes: `used`.
    function bucketSum(Window storage w, uint256 t) internal view returns (uint256 sum) {
        Config memory c = w.config;
        if (c.kind != Kind.SLIDING) return used(w, t);
        uint256 n = c.buckets;
        uint256 bucket = t / c.step;
        uint256 mark = w.mark;
        // Ring position k % n holds bucket k for mark - n < k <= mark.
        uint256 from = bucket + 1 > n ? bucket + 1 - n : 0;
        if (mark + 1 > n && mark + 1 - n > from) from = mark + 1 - n;
        uint256 to = bucket < mark ? bucket : mark;
        for (uint256 k = from; k <= to; ++k) {
            sum += _lane(w, k % n);
        }
    }

    /// @notice Whether consuming `amount` at time `t` stays within the limit.
    function fits(Window storage w, uint256 t, uint64 amount) internal view returns (bool) {
        return uint256(used(w, t)) + amount <= limit(w, t);
    }

    // ------------------------------------------------------------------
    // Writing
    // ------------------------------------------------------------------

    /// @notice Consume `amount` at time `t`. Does not check the limit: the
    ///         policy decides, with `fits`, before it commits.
    function add(Window storage w, uint256 t, uint64 amount) internal {
        Config memory c = w.config;
        _bringTo(w, c, t);
        uint256 next = uint256(w.count) + amount;
        if (next > type(uint64).max) revert WindowLib_Overflow();
        w.count = uint64(next);
        if (c.kind == Kind.SLIDING) {
            uint256 index = (t / c.step) % c.buckets;
            _setLane(w, index, _lane(w, index) + amount); // <= count, so it fits
        }
    }

    /// @notice Give back `amount`, consumed at `placedAt`, at time `t`: an
    ///         order cancelled, or expired unfilled. Returns what was given
    ///         back. Nothing, if the window no longer counts what was consumed
    ///         at `placedAt`; never more than it still counts.
    ///
    ///   SLIDING   to the bucket of `placedAt`, if that bucket is still in the
    ///             window, at most its content
    ///   TUMBLING  if `placedAt` is in the current period
    ///   REFILL    if no refill has happened since `placedAt`, that is, if it
    ///             is in the current interval; a refill may already have given
    ///             the amount back, and giving it again would refund it twice
    ///   STREAM, LIFETIME  always, at most what is counted
    function credit(Window storage w, uint256 t, uint256 placedAt, uint64 amount) internal returns (uint64 credited) {
        Config memory c = w.config;
        _bringTo(w, c, t);
        if (placedAt > t) return 0;

        if (c.kind == Kind.SLIDING) {
            uint256 bucket = placedAt / c.step;
            if (t / c.step - bucket >= c.buckets) return 0;
            uint256 index = bucket % c.buckets;
            uint64 lane = _lane(w, index);
            credited = amount < lane ? amount : lane;
            _setLane(w, index, lane - credited);
        } else {
            if (c.kind == Kind.TUMBLING && _period(c, placedAt) != w.mark) return 0;
            if (c.kind == Kind.REFILL && placedAt / c.step != w.mark) return 0;
            credited = amount < w.count ? amount : w.count;
        }
        w.count -= credited;
    }

    // ------------------------------------------------------------------
    // Internals
    // ------------------------------------------------------------------

    /// @dev Move the stored state to time `t`: expire buckets that left the
    ///      sliding window, start a new tumbling period, apply refills.
    function _bringTo(Window storage w, Config memory c, uint256 t) private {
        if (c.kind == Kind.SLIDING) {
            (uint256 total, bool reset) = _slide(w, c, t);
            uint256 bucket = t / c.step;
            if (reset) {
                // Lazy reset: every bucket left the window. O(1), whatever n.
                w.generation += 1;
            }
            w.count = uint64(total);
            if (bucket > w.mark) w.mark = uint64(bucket);
        } else if (c.kind == Kind.TUMBLING) {
            uint256 period = _period(c, t);
            if (period != w.mark) {
                w.count = 0;
                w.mark = uint64(period);
            }
        } else if (c.kind == Kind.REFILL) {
            uint256 interval = t / c.step;
            w.count = _refilled(w.count, c, w.mark, t);
            if (interval > w.mark) w.mark = uint64(interval);
        }
    }

    /// @dev The sliding total at time `t`, without writing. Advancing from
    ///      bucket `mark` to bucket c expires buckets mark + 1 - n ... c - n,
    ///      which share ring positions with mark + 1 ... c. If c - mark >= n,
    ///      every bucket has expired: total 0, and `reset` is true.
    function _slideView(Window storage w, Config memory c, uint256 t)
        private
        view
        returns (uint256 total, bool reset)
    {
        uint256 n = c.buckets;
        uint256 bucket = t / c.step;
        uint256 mark = w.mark;
        if (bucket <= mark) return (w.count, false);
        if (bucket - mark >= n) return (0, true);

        total = w.count;
        uint256 generation = w.generation;
        uint256 k = mark + 1;
        while (k <= bucket) {
            uint256 index = k % n;
            uint256 word = w.ring[generation][index >> 2];
            // The positions of this storage word that expire, in one read.
            do {
                total -= (word >> ((index & 3) * LANE_BITS)) & LANE_MASK;
                ++k;
                ++index;
            } while (k <= bucket && index < n && index & 3 != 0);
        }
    }

    /// @dev As `_slideView`, and zero the expired positions in storage. On a
    ///      reset nothing is zeroed: the caller bumps the generation instead.
    function _slide(Window storage w, Config memory c, uint256 t) private returns (uint256 total, bool reset) {
        uint256 n = c.buckets;
        uint256 bucket = t / c.step;
        uint256 mark = w.mark;
        if (bucket <= mark) return (w.count, false);
        if (bucket - mark >= n) return (0, true);

        total = w.count;
        uint256 generation = w.generation;
        uint256 k = mark + 1;
        while (k <= bucket) {
            uint256 index = k % n;
            uint256 wordIndex = index >> 2;
            uint256 word = w.ring[generation][wordIndex];
            do {
                uint256 shift = (index & 3) * LANE_BITS;
                total -= (word >> shift) & LANE_MASK;
                word &= ~(LANE_MASK << shift);
                ++k;
                ++index;
            } while (k <= bucket && index < n && index & 3 != 0);
            w.ring[generation][wordIndex] = word;
        }
    }

    function _lane(Window storage w, uint256 index) private view returns (uint64) {
        uint256 word = w.ring[w.generation][index >> 2];
        return uint64((word >> ((index & 3) * LANE_BITS)) & LANE_MASK);
    }

    function _setLane(Window storage w, uint256 index, uint64 value) private {
        uint256 shift = (index & 3) * LANE_BITS;
        mapping(uint256 => uint256) storage words = w.ring[w.generation];
        words[index >> 2] = (words[index >> 2] & ~(LANE_MASK << shift)) | (uint256(value) << shift);
    }

    function _period(Config memory c, uint256 t) private pure returns (uint256) {
        return t > c.anchor ? (t - c.anchor) / c.step : 0;
    }

    /// @dev cap - balance after the refills of intervals mark + 1 ... t / step.
    function _refilled(uint64 usedThen, Config memory c, uint256 mark, uint256 t) private pure returns (uint64) {
        uint256 interval = t / c.step;
        if (interval <= mark) return usedThen;
        uint256 back = (interval - mark) * uint256(c.rate);
        return back >= usedThen ? 0 : uint64(usedThen - back);
    }

    function _restart(Window storage w) private {
        w.generation += 1;
        w.count = 0;
        w.mark = 0;
    }
}
