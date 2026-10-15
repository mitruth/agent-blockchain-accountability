// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {WindowLib} from "../../contracts/policies/WindowLib.sol";
import {WindowProbe} from "../../contracts/harness/WindowProbe.sol";

/// WindowLib, through WindowProbe: each class at its edges, the credits, the
/// configuration rules, the scripted boundary burst of step 3, and a fuzz test
/// per class against a reference model written from the definitions.
contract WindowLibTest is Test {
    WindowProbe internal probe;

    /// 4 October 2024, 00:00 UTC: a day, hour and minute boundary.
    uint256 internal constant D = 1_728_000_000;
    uint32 internal constant HOUR = 3600;
    uint32 internal constant DAY = 86_400;

    uint256 internal constant SLIDING = 1;
    uint256 internal constant TUMBLING = 2;
    uint256 internal constant REFILL = 3;
    uint256 internal constant STREAM = 4;
    uint256 internal constant LIFETIME = 5;

    function setUp() public {
        probe = new WindowProbe();
        vm.warp(D);
    }

    // ------------------------------------------------------------------
    // Configurations
    // ------------------------------------------------------------------

    function _sliding(uint32 step, uint16 buckets, uint64 cap) internal pure returns (WindowLib.Config memory c) {
        c.kind = WindowLib.Kind.SLIDING;
        c.step = step;
        c.buckets = buckets;
        c.cap = cap;
    }

    function _tumbling(uint32 period, uint40 anchor, uint64 cap) internal pure returns (WindowLib.Config memory c) {
        c.kind = WindowLib.Kind.TUMBLING;
        c.step = period;
        c.anchor = anchor;
        c.cap = cap;
    }

    function _refill(uint32 interval, uint64 rate, uint64 cap) internal pure returns (WindowLib.Config memory c) {
        c.kind = WindowLib.Kind.REFILL;
        c.step = interval;
        c.rate = rate;
        c.cap = cap;
    }

    function _stream(uint32 interval, uint40 anchor, uint64 initial, uint64 rate, uint64 cap)
        internal
        pure
        returns (WindowLib.Config memory c)
    {
        c.kind = WindowLib.Kind.STREAM;
        c.step = interval;
        c.anchor = anchor;
        c.initial = initial;
        c.rate = rate;
        c.cap = cap;
    }

    function _lifetime(uint64 cap) internal pure returns (WindowLib.Config memory c) {
        c.kind = WindowLib.Kind.LIFETIME;
        c.cap = cap;
    }

    // ------------------------------------------------------------------
    // SLIDING
    // ------------------------------------------------------------------

    /// 24 one-hour buckets. A bucket counts until the 24th bucket after it
    /// begins: the first second of that bucket, not one second later or earlier.
    function test_slidingCountsTheLastNBucketsExactly() public {
        probe.configure(SLIDING, _sliding(HOUR, 24, 100));
        vm.warp(D + 30 minutes);
        assertTrue(probe.tryAdd(SLIDING, 10));
        vm.warp(D + 5 hours + 30 minutes);
        assertTrue(probe.tryAdd(SLIDING, 20));
        assertEq(probe.used(SLIDING), 30);

        vm.warp(D + 24 hours - 1);
        assertEq(probe.used(SLIDING), 30, "bucket 0 still in the window");
        vm.warp(D + 24 hours);
        assertEq(probe.used(SLIDING), 20, "bucket 0 left the window");
        vm.warp(D + 29 hours - 1);
        assertEq(probe.used(SLIDING), 20, "bucket 5 still in the window");
        vm.warp(D + 29 hours);
        assertEq(probe.used(SLIDING), 0, "bucket 5 left the window");
    }

    /// The cap is inclusive: exactly the cap fits, one more does not.
    function test_slidingAdmitsUpToTheCapInclusive() public {
        probe.configure(SLIDING, _sliding(HOUR, 24, 100));
        assertTrue(probe.tryAdd(SLIDING, 60));
        assertTrue(probe.fits(SLIDING, 40));
        assertFalse(probe.fits(SLIDING, 41));
        assertTrue(probe.tryAdd(SLIDING, 40));
        assertFalse(probe.tryAdd(SLIDING, 1));
        assertEq(probe.used(SLIDING), 100);
    }

    /// The stored state catches up with the clock on the next write, bucket by
    /// bucket, and agrees with the view before and after.
    function test_slidingAdvancesItsStoredStateOnWrite() public {
        probe.configure(SLIDING, _sliding(HOUR, 6, 1000));
        for (uint256 h = 0; h < 6; ++h) {
            vm.warp(D + h * HOUR);
            probe.tryAdd(SLIDING, uint64(10 * (h + 1)));
        }
        vm.warp(D + 8 hours);
        assertEq(probe.used(SLIDING), 150, "buckets 3, 4, 5 remain");
        probe.tryAdd(SLIDING, 7);
        (uint64 count, uint64 mark,) = probe.stored(SLIDING);
        assertEq(count, 157);
        assertEq(mark, (D + 8 hours) / HOUR);
        assertEq(probe.bucketSum(SLIDING), 157);
    }

    /// After an idle gap of at least n buckets everything has expired: the
    /// generation is bumped instead of clearing the ring, and nothing of the
    /// old ring comes back, not even where a new bucket reuses its position.
    function test_slidingResetsLazilyAfterALongIdleGap() public {
        probe.configure(SLIDING, _sliding(HOUR, 24, 100));
        probe.tryAdd(SLIDING, 50);
        (,, uint64 generationBefore) = probe.stored(SLIDING);

        vm.warp(D + 48 hours); // ring position 0 again
        assertEq(probe.used(SLIDING), 0);
        assertTrue(probe.tryAdd(SLIDING, 5));
        (uint64 count,, uint64 generationAfter) = probe.stored(SLIDING);
        assertEq(generationAfter, generationBefore + 1);
        assertEq(count, 5);
        assertEq(probe.bucketSum(SLIDING), 5, "the old bucket at position 0 is gone");

        vm.warp(D + 71 hours);
        assertEq(probe.used(SLIDING), 5);
        probe.observe(SLIDING);
        vm.warp(D + 72 hours);
        assertEq(probe.used(SLIDING), 0);
        assertTrue(probe.tryAdd(SLIDING, 100));
    }

    /// A credit goes back to the bucket the amount was counted in, so it
    /// leaves the window when that bucket does, not when the current one does.
    function test_aCreditReturnsToTheOriginalBucket() public {
        probe.configure(SLIDING, _sliding(HOUR, 24, 100));
        probe.tryAdd(SLIDING, 10); // admission 0, bucket 0
        vm.warp(D + 6 hours);
        probe.tryAdd(SLIDING, 20); // admission 1, bucket 6
        assertEq(probe.credit(SLIDING, 0, 10), 10);
        assertEq(probe.used(SLIDING), 20);

        vm.warp(D + 24 hours); // bucket 0 leaves: it holds nothing any more
        assertEq(probe.used(SLIDING), 20);
        vm.warp(D + 30 hours); // bucket 6 leaves
        assertEq(probe.used(SLIDING), 0);
    }

    /// A partial credit returns only the part credited.
    function test_aPartialCreditReturnsOnlyThatPart() public {
        probe.configure(SLIDING, _sliding(HOUR, 24, 100));
        probe.tryAdd(SLIDING, 40);
        vm.warp(D + 2 hours);
        assertEq(probe.credit(SLIDING, 0, 15), 15);
        assertEq(probe.used(SLIDING), 25);
    }

    /// Once the bucket has left the window there is nothing to give back.
    function test_aCreditOutsideTheWindowIsIgnored() public {
        probe.configure(SLIDING, _sliding(HOUR, 24, 100));
        probe.tryAdd(SLIDING, 10);
        vm.warp(D + 23 hours);
        probe.tryAdd(SLIDING, 30);
        vm.warp(D + 24 hours);
        assertEq(probe.credit(SLIDING, 0, 10), 0);
        assertEq(probe.used(SLIDING), 30, "the credit did not touch the buckets in the window");
    }

    /// The last second the bucket is in the window, the credit applies.
    function test_aCreditInTheLastSecondOfTheWindowApplies() public {
        probe.configure(SLIDING, _sliding(HOUR, 24, 100));
        probe.tryAdd(SLIDING, 10);
        vm.warp(D + 24 hours - 1);
        assertEq(probe.credit(SLIDING, 0, 10), 10);
        assertEq(probe.used(SLIDING), 0);
    }

    /// A credit takes a bucket to zero at most, never below.
    function test_aCreditNeverTakesABucketBelowZero() public {
        probe.configure(SLIDING, _sliding(HOUR, 24, 100));
        probe.tryAdd(SLIDING, 10);
        vm.warp(D + 1 hours);
        probe.tryAdd(SLIDING, 30);
        assertEq(probe.creditAt(SLIDING, D, 25), 10);
        assertEq(probe.used(SLIDING), 30);
        assertEq(probe.bucketSum(SLIDING), 30);
    }

    function test_aCreditDatedInTheFutureIsIgnored() public {
        probe.configure(SLIDING, _sliding(HOUR, 24, 100));
        probe.tryAdd(SLIDING, 10);
        assertEq(probe.creditAt(SLIDING, D + 1, 10), 0);
        assertEq(probe.used(SLIDING), 10);
    }

    /// S1's default window, a week of hourly buckets, at its worst: a write
    /// after 167 buckets of activity, where every position is swept.
    function test_theWorstCaseSweepOfAWeekOfHourlyBucketsIsBounded() public {
        probe.configure(SLIDING, _sliding(HOUR, 168, type(uint64).max));
        for (uint256 h = 0; h < 168; ++h) {
            vm.warp(D + h * HOUR);
            probe.addUnchecked(SLIDING, 1);
        }
        vm.warp(D + 334 hours); // 167 buckets later: all but one expire
        uint256 before = gasleft();
        probe.tryAdd(SLIDING, 1);
        uint256 spent = before - gasleft();
        emit log_named_uint("gas, sweep of 167 hourly buckets", spent);
        assertLt(spent, 600_000);
        assertEq(probe.used(SLIDING), 2);
    }

    // ------------------------------------------------------------------
    // TUMBLING
    // ------------------------------------------------------------------

    /// Daily periods from noon: the count restarts at noon, to the second.
    function test_tumblingRestartsAtEachPeriodBoundary() public {
        probe.configure(TUMBLING, _tumbling(DAY, uint40(D + 12 hours), 100));
        vm.warp(D + 13 hours);
        probe.tryAdd(TUMBLING, 70);
        vm.warp(D + 36 hours - 1);
        assertEq(probe.used(TUMBLING), 70);
        vm.warp(D + 36 hours);
        assertEq(probe.used(TUMBLING), 0);
        assertTrue(probe.tryAdd(TUMBLING, 100));
    }

    /// Before the anchor the count belongs to the first period.
    function test_tumblingCountsTimeBeforeTheAnchorInTheFirstPeriod() public {
        probe.configure(TUMBLING, _tumbling(DAY, uint40(D + 12 hours), 100));
        vm.warp(D + 1 hours);
        probe.tryAdd(TUMBLING, 30);
        vm.warp(D + 20 hours);
        assertEq(probe.used(TUMBLING), 30);
        vm.warp(D + 36 hours);
        assertEq(probe.used(TUMBLING), 0);
    }

    function test_tumblingCreditsOnlyWithinThePeriod() public {
        probe.configure(TUMBLING, _tumbling(DAY, uint40(D), 100));
        probe.tryAdd(TUMBLING, 40); // 0
        probe.tryAdd(TUMBLING, 40); // 1
        vm.warp(D + 23 hours);
        assertEq(probe.credit(TUMBLING, 0, 40), 40);
        assertEq(probe.used(TUMBLING), 40);
        vm.warp(D + 25 hours);
        probe.tryAdd(TUMBLING, 10);
        assertEq(probe.credit(TUMBLING, 1, 40), 0, "admission 1 belongs to the previous period");
        assertEq(probe.used(TUMBLING), 10);
    }

    // ------------------------------------------------------------------
    // The scripted boundary burst (step 3 acceptance)
    // ------------------------------------------------------------------

    /// The cap spent in the last second before midnight, and again in the
    /// first second after: a daily tumbling window admits twice its cap within
    /// two seconds; a 24-hour sliding window with the same cap admits it once.
    function test_aBoundaryBurstAdmitsTwiceTheCapUnderTumblingAndOnceUnderSliding() public {
        uint64 cap = 1000;
        probe.configure(SLIDING, _sliding(HOUR, 24, cap));
        probe.configure(TUMBLING, _tumbling(DAY, uint40(D), cap));

        vm.warp(D + DAY - 1);
        assertTrue(probe.tryAdd(SLIDING, cap));
        assertTrue(probe.tryAdd(TUMBLING, cap));

        vm.warp(D + DAY + 1);
        assertFalse(probe.tryAdd(SLIDING, cap), "sliding: the cap already spent is still in the window");
        assertTrue(probe.tryAdd(TUMBLING, cap), "tumbling: the count restarted at midnight");

        assertEq(probe.admissionCount(SLIDING) * cap, cap, "sliding admitted H in two seconds");
        assertEq(probe.admissionCount(TUMBLING) * cap, 2 * cap, "tumbling admitted 2H in two seconds");
    }

    // ------------------------------------------------------------------
    // REFILL
    // ------------------------------------------------------------------

    /// 10 back every hour, on the hour, up to 100. A partial hour gives nothing.
    function test_refillGivesBackItsRateEachInterval() public {
        probe.configure(REFILL, _refill(HOUR, 10, 100));
        vm.warp(D + 30 minutes);
        assertTrue(probe.tryAdd(REFILL, 100));
        assertFalse(probe.tryAdd(REFILL, 1));
        vm.warp(D + 1 hours - 1);
        assertFalse(probe.fits(REFILL, 1));
        vm.warp(D + 1 hours);
        assertEq(probe.used(REFILL), 90);
        assertTrue(probe.tryAdd(REFILL, 10));
        assertFalse(probe.tryAdd(REFILL, 1));
        vm.warp(D + 5 hours);
        assertEq(probe.used(REFILL), 60);
    }

    /// After a long idle period the bucket is full, and no fuller: the whole
    /// capacity can be spent at once (the idle-then-burst baseline).
    function test_refillNeverHoldsMoreThanItsCapacity() public {
        probe.configure(REFILL, _refill(HOUR, 10, 100));
        probe.tryAdd(REFILL, 30);
        vm.warp(D + 365 days);
        assertEq(probe.used(REFILL), 0);
        assertTrue(probe.tryAdd(REFILL, 100));
        assertFalse(probe.tryAdd(REFILL, 1));
    }

    /// A credit is given only while no refill has happened since the amount
    /// was consumed; afterwards the refill may already have given it back.
    function test_refillCreditsOnlyWithinTheSameInterval() public {
        probe.configure(REFILL, _refill(HOUR, 10, 100));
        vm.warp(D + 10 minutes);
        probe.tryAdd(REFILL, 50); // 0
        vm.warp(D + 50 minutes);
        assertEq(probe.credit(REFILL, 0, 50), 50);
        assertEq(probe.used(REFILL), 0);

        vm.warp(D + 1 hours + 10 minutes);
        probe.tryAdd(REFILL, 50); // 1
        vm.warp(D + 2 hours + 5 minutes);
        assertEq(probe.credit(REFILL, 1, 50), 0);
        assertEq(probe.used(REFILL), 40);
    }

    // ------------------------------------------------------------------
    // STREAM
    // ------------------------------------------------------------------

    /// 20 at the anchor, 10 more each hour, never more than 100.
    function test_streamUnlocksOverTime() public {
        probe.configure(STREAM, _stream(HOUR, uint40(D), 20, 10, 100));
        vm.warp(D + 30 minutes);
        assertEq(probe.limit(STREAM), 20);
        assertTrue(probe.tryAdd(STREAM, 20));
        assertFalse(probe.tryAdd(STREAM, 1));
        vm.warp(D + 1 hours);
        assertEq(probe.limit(STREAM), 30);
        assertTrue(probe.tryAdd(STREAM, 10));
        vm.warp(D + 20 hours);
        assertEq(probe.limit(STREAM), 100);
        assertTrue(probe.tryAdd(STREAM, 70), "idle, then the whole unlocked rest at once");
        assertFalse(probe.tryAdd(STREAM, 1));
    }

    function test_streamUnlocksOnlyTheInitialAmountBeforeItsAnchor() public {
        probe.configure(STREAM, _stream(HOUR, uint40(D + DAY), 20, 10, 100));
        vm.warp(D + 5 hours);
        assertEq(probe.limit(STREAM), 20);
    }

    function test_streamCreditsGiveTheAllowanceBack() public {
        probe.configure(STREAM, _stream(HOUR, uint40(D), 50, 0, 50));
        probe.tryAdd(STREAM, 50);
        vm.warp(D + 30 days);
        assertEq(probe.credit(STREAM, 0, 20), 20);
        assertTrue(probe.tryAdd(STREAM, 20));
    }

    // ------------------------------------------------------------------
    // LIFETIME
    // ------------------------------------------------------------------

    function test_lifetimeNeverResets() public {
        probe.configure(LIFETIME, _lifetime(100));
        probe.tryAdd(LIFETIME, 60);
        vm.warp(D + 365 days);
        assertFalse(probe.tryAdd(LIFETIME, 41));
        assertTrue(probe.tryAdd(LIFETIME, 40));
        assertEq(probe.credit(LIFETIME, 0, 10), 10);
        assertTrue(probe.tryAdd(LIFETIME, 10));
        assertEq(probe.used(LIFETIME), 100);
    }

    /// A count beyond 64 bits reverts rather than wrapping.
    function test_aCountBeyondSixtyFourBitsReverts() public {
        probe.configure(LIFETIME, _lifetime(type(uint64).max));
        probe.addUnchecked(LIFETIME, type(uint64).max);
        vm.expectRevert(WindowLib.WindowLib_Overflow.selector);
        probe.addUnchecked(LIFETIME, 1);
    }

    // ------------------------------------------------------------------
    // Configuration
    // ------------------------------------------------------------------

    function test_malformedConfigurationsAreRefused() public {
        WindowLib.Config[7] memory bad = [
            _sliding(0, 24, 100),
            _sliding(HOUR, 0, 100),
            _sliding(HOUR, 2017, 100),
            _tumbling(0, 0, 100),
            _refill(0, 10, 100),
            _stream(0, 0, 10, 10, 100),
            _stream(HOUR, 0, 101, 10, 100)
        ];
        for (uint256 i = 0; i < bad.length; ++i) {
            vm.expectRevert(WindowLib.WindowLib_InvalidConfig.selector);
            probe.configure(SLIDING, bad[i]);
        }
        probe.configure(SLIDING, _sliding(300, 2016, 100)); // a week of 5-minute buckets: the most allowed
    }

    /// A new cap keeps what was counted; a new shape starts afresh.
    function test_aChangeOfShapeStartsAfreshAndAChangeOfCapDoesNot() public {
        probe.configure(SLIDING, _sliding(HOUR, 24, 100));
        probe.tryAdd(SLIDING, 50);
        probe.configure(SLIDING, _sliding(HOUR, 24, 60));
        assertEq(probe.used(SLIDING), 50);
        assertFalse(probe.tryAdd(SLIDING, 11));

        probe.configure(SLIDING, _sliding(HOUR, 12, 60));
        assertEq(probe.used(SLIDING), 0);
        assertEq(probe.bucketSum(SLIDING), 0);

        probe.configure(SLIDING, _tumbling(DAY, uint40(D), 60));
        assertEq(probe.used(SLIDING), 0);
    }

    /// Starting afresh must make the old buckets unreachable, not merely zero
    /// the total. Usually the next write's lazy reset would hide a stale ring;
    /// with buckets longer than the time since 1970 every write lands in
    /// bucket 0, so nothing else clears it.
    function test_aRestartLeavesNothingOfTheOldRing() public {
        uint32 longStep = uint32(1) << 31; // about 68 years: today is in bucket 0
        probe.configure(SLIDING, _sliding(longStep, 2, 1000));
        probe.tryAdd(SLIDING, 50);
        probe.configure(SLIDING, _sliding(longStep, 3, 1000)); // a new shape: start afresh
        assertTrue(probe.tryAdd(SLIDING, 10));
        assertEq(probe.used(SLIDING), 10);
        assertEq(probe.bucketSum(SLIDING), 10, "the old ring's 50 is gone");
    }

    function test_clearForgetsEverythingCounted() public {
        probe.configure(SLIDING, _sliding(HOUR, 24, 100));
        probe.tryAdd(SLIDING, 50);
        probe.clear(SLIDING);
        assertEq(probe.used(SLIDING), 0);
        assertTrue(probe.tryAdd(SLIDING, 100));
    }

    // ------------------------------------------------------------------
    // Fuzz: every class against a reference model
    // ------------------------------------------------------------------
    //
    // A random sequence of waits, admissions, credits and observations. The
    // model keeps every admission with its time and recomputes the window's
    // count from the definition after every step; the probe's decision, count
    // and limit must match. For SLIDING, the running total must also equal the
    // buckets summed one by one.

    struct Rec {
        uint64 amount;
        uint256 at;
        bool credited;
        bool creditApplied;
        uint64 credit;
    }

    Rec[] internal recs;

    // REFILL's model state: the same recursion as its definition.
    uint256 internal refillUsed;
    uint256 internal refillMark;

    function testFuzz_slidingAgreesWithTheModel(uint256 seed) public {
        _fuzz(WindowLib.Kind.SLIDING, seed);
    }

    function testFuzz_tumblingAgreesWithTheModel(uint256 seed) public {
        _fuzz(WindowLib.Kind.TUMBLING, seed);
    }

    function testFuzz_refillAgreesWithTheModel(uint256 seed) public {
        _fuzz(WindowLib.Kind.REFILL, seed);
    }

    function testFuzz_streamAgreesWithTheModel(uint256 seed) public {
        _fuzz(WindowLib.Kind.STREAM, seed);
    }

    function testFuzz_lifetimeAgreesWithTheModel(uint256 seed) public {
        _fuzz(WindowLib.Kind.LIFETIME, seed);
    }

    function _fuzz(WindowLib.Kind kind, uint256 seed) internal {
        WindowLib.Config memory c;
        c.kind = kind;
        c.step = uint32(60 * (1 + _rand(seed, 1) % 10));
        c.buckets = kind == WindowLib.Kind.SLIDING ? uint16(1 + _rand(seed, 2) % 9) : 0;
        c.anchor = uint40(D + _rand(seed, 3) % (2 * uint256(c.step)));
        c.cap = 1000;
        c.rate = uint64(1 + _rand(seed, 4) % 300);
        c.initial = kind == WindowLib.Kind.STREAM ? uint64(_rand(seed, 5) % 1001) : 0;
        probe.configure(1, c);
        refillUsed = 0;
        refillMark = 0;

        uint256 t = D;
        uint256 span = (c.buckets == 0 ? 3 : uint256(c.buckets) + 2) * c.step;
        for (uint256 i = 0; i < 40; ++i) {
            uint256 r = _rand(seed, 100 + i);
            uint256 wait = r % 8;
            if (wait >= 1 && wait <= 4) t += (r >> 8) % c.step;
            else if (wait <= 6 && wait != 0) t += (r >> 8) % (3 * uint256(c.step));
            else if (wait == 7) t += (r >> 8) % span;
            vm.warp(t);

            uint256 op = (r >> 64) % 10;
            if (op < 6) {
                uint64 amount = uint64((r >> 96) % 400);
                bool expected = _modelUsed(c, t) + amount <= _modelLimit(c, t);
                assertEq(probe.used(1), _modelUsed(c, t), "count before the admission");
                bool admitted = probe.tryAdd(1, amount);
                assertEq(admitted, expected, "admission decision");
                if (admitted) {
                    _refillTo(c, t);
                    refillUsed += amount;
                    recs.push(Rec({amount: amount, at: t, credited: false, creditApplied: false, credit: 0}));
                }
            } else if (op < 8 && recs.length > 0) {
                uint256 k = (r >> 96) % recs.length;
                if (!recs[k].credited) {
                    uint64 amount = uint64((r >> 128) % (uint256(recs[k].amount) + 1));
                    bool applies = _creditApplies(c, recs[k].at, t);
                    _refillTo(c, t);
                    uint64 credited = probe.credit(1, k, amount);
                    assertEq(credited, applies ? amount : 0, "credit");
                    recs[k].credited = true;
                    recs[k].creditApplied = applies;
                    recs[k].credit = amount;
                    if (applies) refillUsed -= amount;
                }
            }
            assertEq(probe.used(1), _modelUsed(c, t), "count");
            assertEq(probe.limit(1), _modelLimit(c, t), "limit");
            if (kind == WindowLib.Kind.SLIDING) assertEq(probe.bucketSum(1), probe.used(1), "total = sum of buckets");
        }
    }

    function _rand(uint256 seed, uint256 i) internal pure returns (uint256) {
        return uint256(keccak256(abi.encode(seed, i)));
    }

    function _period(WindowLib.Config memory c, uint256 t) internal pure returns (uint256) {
        return t > c.anchor ? (t - c.anchor) / c.step : 0;
    }

    function _counts(WindowLib.Config memory c, uint256 at, uint256 t) internal pure returns (bool) {
        if (c.kind == WindowLib.Kind.SLIDING) return t / c.step - at / c.step < c.buckets;
        if (c.kind == WindowLib.Kind.TUMBLING) return _period(c, at) == _period(c, t);
        return true;
    }

    function _creditApplies(WindowLib.Config memory c, uint256 at, uint256 t) internal pure returns (bool) {
        if (c.kind == WindowLib.Kind.REFILL) return at / c.step == t / c.step;
        return _counts(c, at, t);
    }

    function _modelUsed(WindowLib.Config memory c, uint256 t) internal view returns (uint256 sum) {
        if (c.kind == WindowLib.Kind.REFILL) {
            uint256 back = (t / c.step - refillMark) * c.rate;
            return back >= refillUsed ? 0 : refillUsed - back;
        }
        for (uint256 i = 0; i < recs.length; ++i) {
            if (!_counts(c, recs[i].at, t)) continue;
            sum += recs[i].amount;
            if (recs[i].creditApplied) sum -= recs[i].credit;
        }
    }

    function _modelLimit(WindowLib.Config memory c, uint256 t) internal pure returns (uint256) {
        if (c.kind != WindowLib.Kind.STREAM) return c.cap;
        uint256 unlocked = c.initial + (t > c.anchor ? (t - c.anchor) / c.step : 0) * c.rate;
        return unlocked < c.cap ? unlocked : c.cap;
    }

    function _refillTo(WindowLib.Config memory c, uint256 t) internal {
        if (c.kind != WindowLib.Kind.REFILL) return;
        uint256 back = (t / c.step - refillMark) * c.rate;
        refillUsed = back >= refillUsed ? 0 : refillUsed - back;
        refillMark = t / c.step;
    }
}
