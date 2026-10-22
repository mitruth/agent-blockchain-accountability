// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import {Vm} from "forge-std/Test.sol";
import {console} from "forge-std/console.sol";
import {PolicyFixture} from "../policies/PolicyFixture.sol";
import {PolicyGate} from "../../contracts/gate/PolicyGate.sol";
import {SessionBreaker} from "../../contracts/gate/SessionBreaker.sol";
import {WindowPolicy} from "../../contracts/policies/WindowPolicy.sol";
import {CancelQuotaPolicy} from "../../contracts/policies/CancelQuotaPolicy.sol";
import {WindowLib} from "../../contracts/policies/WindowLib.sol";
import {MockEnergyMarket} from "./mocks/MockEnergyMarket.sol";
import {Side} from "../../contracts/gate/GateTypes.sol";
import {SignedReading} from "../../contracts/oracle/OracleTypes.sol";

/// @notice G1, the session circuit breaker (spec v0.2 section 5), through the
///         gate on the mock market. The agent spends under S1, a budget of
///         1,000,000 units (1 USD) a day, flagged above 100,000: at 0.25 per
///         kWh, 4,000 Wh fit and anything above 400 Wh is flagged.
contract SessionBreakerTest is PolicyFixture {
    bytes32 internal constant S1 = keccak256("S1");
    uint64 internal constant CAP = 1_000_000;
    uint64 internal constant SOFT = 100_000;
    /// @dev The largest bid S1 admits: 4,000 Wh at 0.25 is the cap exactly.
    uint64 internal constant CAP_WH = 4_000;

    SessionBreaker internal breaker;
    WindowPolicy internal s1;

    event AgentSuspended(
        address indexed account, SessionBreaker.Reason reason, uint64 rejectsUsed, uint64 flagsUsed, uint48 at
    );
    event AgentReinstated(address indexed account, SessionBreaker.Reinstatement how, uint48 at);

    function setUp() public override {
        super.setUp();
        breaker = gate.breaker();
        s1 = new WindowPolicy(address(gate));
        WindowLib.Config memory w = _sliding(3600, 24, CAP);
        _addPolicy(s1, S1, abi.encode(WindowPolicy.Config({quantity: WindowPolicy.Quantity.BUY_VALUE, soft: SOFT, window: w})));
    }

    // --- helpers ------------------------------------------------------------

    function _sliding(uint32 step, uint16 buckets, uint64 cap) internal pure returns (WindowLib.Config memory w) {
        w.kind = WindowLib.Kind.SLIDING;
        w.step = step;
        w.buckets = buckets;
        w.cap = cap;
    }

    /// @dev The spec's shapes: rejects 1 h in 5-minute buckets, flags 24 h in
    ///      hourly buckets.
    function _config(uint64 maxRejects, uint64 maxFlags, uint32 cooldown) internal pure returns (bytes memory) {
        return abi.encode(
            SessionBreaker.Config({
                rejects: _sliding(300, 12, maxRejects),
                flags: _sliding(3600, 24, maxFlags),
                cooldownSeconds: cooldown
            })
        );
    }

    function _setBreaker(bytes memory config) internal returns (bool applied) {
        vm.prank(owner);
        bytes memory out = account.execute(address(gate), 0, abi.encodeCall(gate.setBreakerConfig, (config)));
        return abi.decode(out, (bool));
    }

    function _state() internal view returns (SessionBreaker.State memory) {
        return breaker.stateOf(address(account), gate.generationOf(address(account)));
    }

    function _bid(uint64 qtyWh) internal returns (bytes32) {
        return _place(Side.BUY, _slot(), qtyWh, PRICE);
    }

    /// @dev A slot well ahead of now, whatever the time.
    function _slot() internal view returns (uint32) {
        return market.currentSlot() + 10;
    }

    /// @dev Suspend the account with R_max = 0: one rejection is too many.
    function _suspend() internal {
        _setBreaker(_config(0, 30, 0));
        assertEq(_bid(CAP_WH + 1), bytes32(0));
        assertTrue(_state().suspended);
    }

    // ------------------------------------------------------------------
    // Spec section 7: the probing campaign
    // ------------------------------------------------------------------

    /// @dev A binary search for S1's cap, one rejected submission at a time,
    ///      cancelling what fits so the budget is not spent. Returns the
    ///      largest bid the agent learnt is admitted, and the probes made.
    function _probe() internal returns (uint64 learnt, uint256 probes) {
        uint64 lo = 0;
        uint64 hi = uint64(1) << 30;
        while (hi - lo > 1) {
            uint64 mid = lo + (hi - lo) / 2;
            bytes32 id = _bid(mid);
            ++probes;
            if (id != bytes32(0)) {
                _cancel(id);
                lo = mid;
            } else {
                hi = mid;
            }
        }
        return (lo, probes);
    }

    /// @dev Without G1 the search runs to the end and finds the cap to the Wh.
    function test_probingCampaign_findsTheCapWithoutG1() public {
        (uint64 learnt, uint256 probes) = _probe();
        assertEq(learnt, CAP_WH, "the cap, found");
        assertEq(probes, 30);
    }

    /// @dev With G1 at the spec's defaults (R_max 10 an hour), the eleventh
    ///      rejection suspends the account; every probe after it is refused
    ///      whatever its size, so the search learns nothing more.
    function test_probingCampaign_isSuspendedByG1() public {
        assertTrue(_setBreaker(_config(10, 30, 0)));
        vm.recordLogs();
        (uint64 learnt,) = _probe();
        assertTrue(_state().suspended);

        // One suspension, with the counts that tripped it.
        Vm.Log[] memory logs = vm.getRecordedLogs();
        uint256 found;
        for (uint256 i = 0; i < logs.length; ++i) {
            if (logs[i].emitter != address(breaker) || logs[i].topics[0] != AgentSuspended.selector) continue;
            (SessionBreaker.Reason reason, uint64 rejectsUsed, uint64 flagsUsed, uint48 at) =
                abi.decode(logs[i].data, (SessionBreaker.Reason, uint64, uint64, uint48));
            assertEq(uint8(reason), uint8(SessionBreaker.Reason.REJECTS));
            assertEq(rejectsUsed, 11, "the eleventh rejection");
            assertEq(flagsUsed, 0);
            assertEq(at, block.timestamp);
            ++found;
        }
        assertEq(found, 1);
        assertEq(learnt, 0, "every probe refused once suspended: nothing learnt");
        assertEq(market.orderCount(), 0, "nothing reached the market");
    }

    // ------------------------------------------------------------------
    // Spec section 7: the on-off agent
    // ------------------------------------------------------------------

    /// @dev Two flagged bids, one a slot, then ten slots at rest, again and
    ///      again (the adaptive on-off pattern). Each bid is cancelled so the
    ///      budget never binds. With F_max = 5 in a day, the sixth flag, in
    ///      the third burst (10 hours on), suspends the account.
    function test_onOffAgent_isSuspendedWithinTheFlagWindow() public {
        _setBreaker(_config(10, 5, 0));
        uint256 flags;
        for (uint256 burst = 0; burst < 4 && !_state().suspended; ++burst) {
            for (uint256 k = 0; k < 2 && !_state().suspended; ++k) {
                bytes32 id = _bid(1_000);
                ++flags;
                if (id != bytes32(0)) _cancel(id);
                vm.warp(block.timestamp + SLOT_SECONDS);
            }
            vm.warp(block.timestamp + 10 * SLOT_SECONDS);
        }
        assertTrue(_state().suspended);
        assertEq(flags, 6);
    }

    /// @dev The same bursts a day and an hour apart never put more than two
    ///      flags in the window.
    function test_onOffAgent_spacedBeyondTheWindowIsNeverSuspended() public {
        _setBreaker(_config(10, 2, 0));
        for (uint256 burst = 0; burst < 4; ++burst) {
            for (uint256 k = 0; k < 2; ++k) {
                bytes32 id = _bid(1_000);
                assertTrue(id != bytes32(0));
                _cancel(id);
                vm.warp(block.timestamp + SLOT_SECONDS);
            }
            vm.warp(block.timestamp + 25 hours);
        }
        assertFalse(_state().suspended);
    }

    /// @dev A clean submission is never judged, so it never suspends.
    function test_cleanSubmissionsNeverSuspend() public {
        _setBreaker(_config(0, 0, 0));
        for (uint256 i = 0; i < 5; ++i) {
            _cancel(_bid(100));
        }
        assertFalse(_state().suspended);
    }

    // ------------------------------------------------------------------
    // Cancel-only while suspended (D17)
    // ------------------------------------------------------------------

    function test_whileSuspended_aCancellationPasses() public {
        bytes32 id = _bid(100);
        _suspend();
        _cancel(id);
        assertFalse(market.isOpen(id), "cancelled");
    }

    function test_whileSuspended_placementsAndModificationsAreRefused() public {
        bytes32 id = _bid(100);
        _suspend();
        vm.recordLogs();
        assertEq(_bid(100), bytes32(0), "a placement refused");
        assertTrue(_logged(vm.getRecordedLogs(), PolicyGate.SuspendedRefusal.selector));

        _submit(abi.encodeCall(MockEnergyMarket.modifyOrder, (id, _slot(), 50, PRICE)));
        assertTrue(market.isOpen(id), "a smaller modification refused too");
        assertEq(market.orderCount(), 1);
    }

    /// @dev The policies still judge a cancellation while suspended: S6, with
    ///      a quota of 100 Wh cancelled an hour, refuses this 500 Wh one.
    function test_whileSuspended_thePoliciesStillJudgeACancellation() public {
        bytes32 id = _bid(500);
        CancelQuotaPolicy s6 = new CancelQuotaPolicy(address(gate));
        _addPolicy(
            s6,
            keccak256("S6"),
            abi.encode(
                CancelQuotaPolicy.Config({
                    window: _sliding(300, 12, 0),
                    maxCancelledWh: 100,
                    maxMessages: 100,
                    gateWeightPercent: 100,
                    gateWindowSeconds: 0,
                    ratioPercent: 1_000,
                    freeCancelWh: 1_000
                })
            )
        );
        _suspend();
        vm.recordLogs();
        _cancel(id);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertTrue(market.isOpen(id), "S6 refused it");
        assertFalse(_logged(logs, PolicyGate.SuspendedRefusal.selector), "not refused by G1");
        assertTrue(_logged(logs, PolicyGate.Rejected.selector));
        // A rejection while suspended is not counted: the window still holds
        // only the one that tripped the breaker.
        (uint64 rejects,) = breaker.usedOf(address(account), gate.generationOf(address(account)));
        assertEq(rejects, 1);
    }

    /// @dev Nothing counts while suspended: the windows hold what tripped it.
    function test_whileSuspended_nothingIsCounted() public {
        _suspend();
        _bid(CAP_WH + 1);
        _bid(CAP_WH + 1);
        (uint64 rejects,) = breaker.usedOf(address(account), gate.generationOf(address(account)));
        assertEq(rejects, 1);
    }

    // ------------------------------------------------------------------
    // Reinstatement
    // ------------------------------------------------------------------

    /// @dev R_max 1: two rejections suspend. The owner reinstates, and both
    ///      windows start empty, so a third rejection alone does not suspend.
    function test_ownerReinstatementClearsTheWindows() public {
        _setBreaker(_config(1, 30, 0));
        _bid(CAP_WH + 1);
        _bid(CAP_WH + 1);
        assertTrue(_state().suspended);

        vm.expectEmit(true, true, true, true, address(breaker));
        emit AgentReinstated(address(account), SessionBreaker.Reinstatement.OWNER, uint48(block.timestamp));
        _asAccount(abi.encodeCall(gate.reinstate, ()));
        assertFalse(_state().suspended);

        _bid(CAP_WH + 1);
        assertFalse(_state().suspended, "one rejection after a fresh start");
        assertTrue(_bid(100) != bytes32(0), "trading again");
    }

    function test_reinstatingAnActiveAccountReverts() public {
        _setBreaker(_config(1, 30, 0));
        vm.prank(owner);
        vm.expectRevert();
        account.execute(address(gate), 0, abi.encodeCall(gate.reinstate, ()));
    }

    /// @dev A cooldown of 10 minutes: one second early, still suspended; at
    ///      the cooldown's end, the next submission is reinstated and placed.
    function test_autoReinstatementAfterTheCooldown() public {
        _setBreaker(_config(0, 30, 600));
        uint256 t = block.timestamp;
        _bid(CAP_WH + 1);
        assertTrue(_state().suspended);

        vm.warp(t + 599);
        assertEq(_bid(100), bytes32(0), "one second early");

        vm.warp(t + 600);
        vm.expectEmit(true, true, true, true, address(breaker));
        emit AgentReinstated(address(account), SessionBreaker.Reinstatement.AUTO, uint48(t + 600));
        assertTrue(_bid(100) != bytes32(0), "reinstated and placed");
        assertFalse(_state().suspended);
    }

    // ------------------------------------------------------------------
    // Configuration
    // ------------------------------------------------------------------

    function test_unconfiguredG1NeverSuspends() public {
        for (uint256 i = 0; i < 20; ++i) {
            _bid(CAP_WH + 1);
        }
        assertFalse(_state().on);
        assertFalse(_state().suspended);
    }

    /// @dev Turning G1 on, a lower cap, a longer cooldown, and no cooldown at
    ///      all (owner only, the tightest) all apply at once.
    function test_everyTighteningAppliesAtOnce() public {
        assertTrue(_setBreaker(_config(10, 30, 3600)), "on");
        assertTrue(_setBreaker(_config(5, 30, 3600)), "a lower reject cap");
        assertTrue(_setBreaker(_config(5, 20, 3600)), "a lower flag cap");
        assertTrue(_setBreaker(_config(5, 20, 7200)), "a longer cooldown");
        assertTrue(_setBreaker(_config(5, 20, 0)), "owner reinstatement only");
        assertFalse(_setBreaker(_config(5, 20, 7200)), "from owner-only to any cooldown: a widening");
    }

    /// @dev Every loosening waits 24 hours: a higher cap, another window
    ///      shape, a shorter cooldown, turning G1 off.
    function test_everyLooseningWaits() public {
        _setBreaker(_config(5, 30, 7200));
        bytes[5] memory looser = [
            _config(6, 30, 7200),
            _config(5, 31, 7200),
            _config(5, 30, 3600),
            abi.encode(
                SessionBreaker.Config({rejects: _sliding(600, 6, 5), flags: _sliding(3600, 24, 30), cooldownSeconds: 7200})
            ),
            bytes("")
        ];
        uint64 g = gate.generationOf(address(account));
        for (uint256 i = 0; i < looser.length; ++i) {
            assertFalse(_setBreaker(looser[i]), "queued, not applied");
            assertEq(breaker.proposalOf(address(account), g).configHash, keccak256(looser[i]));
        }
    }

    function test_aWideningAppliesAfterTheTimelockOnly() public {
        _setBreaker(_config(5, 30, 0));
        bytes memory wider = _config(10, 30, 0);
        _setBreaker(wider);

        vm.prank(owner);
        vm.expectRevert();
        account.execute(address(gate), 0, abi.encodeCall(gate.applyBreakerConfig, (wider)));

        vm.warp(block.timestamp + 24 hours);
        _asAccount(abi.encodeCall(gate.applyBreakerConfig, (wider)));
        assertEq(breaker.configOf(address(account), gate.generationOf(address(account))).rejects.cap, 10);
    }

    /// @dev Any later write drops a queued widening.
    function test_aLaterWriteDropsAQueuedWidening() public {
        _setBreaker(_config(5, 30, 0));
        bytes memory wider = _config(10, 30, 0);
        _setBreaker(wider);
        _setBreaker(_config(4, 30, 0));
        vm.warp(block.timestamp + 24 hours);
        vm.prank(owner);
        vm.expectRevert();
        account.execute(address(gate), 0, abi.encodeCall(gate.applyBreakerConfig, (wider)));
    }

    function test_aMalformedConfigurationIsRefused() public {
        bytes memory tumbling = abi.encode(
            SessionBreaker.Config({
                rejects: WindowLib.Config({kind: WindowLib.Kind.TUMBLING, step: 3600, buckets: 0, anchor: 0, cap: 10, rate: 0, initial: 0}),
                flags: _sliding(3600, 24, 30),
                cooldownSeconds: 0
            })
        );
        vm.prank(owner);
        vm.expectRevert();
        account.execute(address(gate), 0, abi.encodeCall(gate.setBreakerConfig, (tumbling)));

        vm.prank(owner);
        vm.expectRevert();
        account.execute(address(gate), 0, abi.encodeCall(gate.setBreakerConfig, (_config(10, 30, 31 days))));
    }

    /// @dev A reinstalled gate starts with G1 off and nothing counted.
    function test_aReinstallClearsTheBreaker() public {
        _suspend();
        vm.startPrank(owner);
        account.uninstallModule(EXECUTOR, address(gate), "");
        account.installModule(EXECUTOR, address(gate), "");
        vm.stopPrank();
        assertFalse(_state().on);
        assertFalse(_state().suspended);
    }

    // ------------------------------------------------------------------
    // Out of the agent's reach
    // ------------------------------------------------------------------

    function test_theAgentCannotReachTheBreaker() public {
        vm.expectRevert(abi.encodeWithSelector(PolicyGate.PolicyGate_ForbiddenTarget.selector, address(breaker)));
        _submitTo(address(breaker), abi.encodeCall(SessionBreaker.reinstate, (address(account), 1)));

        bytes[2] memory gateCalls =
            [abi.encodeCall(PolicyGate.reinstate, ()), abi.encodeCall(PolicyGate.setBreakerConfig, (bytes("")))];
        for (uint256 i = 0; i < gateCalls.length; ++i) {
            vm.expectRevert(abi.encodeWithSelector(PolicyGate.PolicyGate_ForbiddenTarget.selector, address(gate)));
            _submitTo(address(gate), gateCalls[i]);
        }
    }

    function test_onlyTheGateWritesTheBreaker() public {
        vm.expectRevert(abi.encodeWithSelector(SessionBreaker.Breaker_OnlyGate.selector, address(this)));
        breaker.record(address(account), 1, true, false);
        vm.expectRevert(abi.encodeWithSelector(SessionBreaker.Breaker_OnlyGate.selector, address(this)));
        breaker.reinstate(address(account), 1);
        vm.expectRevert(abi.encodeWithSelector(SessionBreaker.Breaker_OnlyGate.selector, address(this)));
        breaker.setConfig(address(account), 1, bytes(""));
    }

    // ------------------------------------------------------------------
    // Gas: what G1 adds to a submission
    // ------------------------------------------------------------------

    function _gasOfBid(uint64 qtyWh) internal returns (uint256 used) {
        bytes memory sub =
            abi.encodeCall(gate.submit, (address(market), _placeCall(Side.BUY, _slot(), qtyWh, PRICE), new SignedReading[](0)));
        vm.prank(agent);
        uint256 before = gasleft();
        account.executeAsSession(address(gate), sub);
        used = before - gasleft();
    }

    /// @dev Steady state: one bid placed and cancelled first. Then a clean
    ///      bid, a flagged one and a rejected one, with G1 off and on; and a
    ///      bid refused while suspended.
    function test_gas_G1() public {
        _cancel(_bid(100));
        _report("G1 off");
        _setBreaker(_config(1_000, 1_000, 0));
        _report("G1 on");

        _setBreaker(_config(0, 1_000, 0));
        _bid(CAP_WH + 1);
        assertTrue(_state().suspended);
        _gasOfBid(100);
        console.log("G1 suspended, refused bid:", _gasOfBid(100));
    }

    /// @dev Each kind of submission twice, the second reported: the first
    ///      pays for storage written for the first time. A bid that was placed
    ///      is cancelled after it is measured, so the budget never binds.
    function _report(string memory label) internal {
        _measure(100);
        console.log(label, "clean bid:", _measure(100));
        _measure(1_000);
        console.log(label, "flagged bid:", _measure(1_000));
        _measure(CAP_WH + 1);
        console.log(label, "rejected bid:", _measure(CAP_WH + 1));
    }

    function _measure(uint64 qtyWh) internal returns (uint256 used) {
        uint256 before = market.orderCount();
        used = _gasOfBid(qtyWh);
        if (market.orderCount() > before) _cancel(bytes32(market.orderCount()));
    }

    // ------------------------------------------------------------------

    function _submitTo(address target, bytes memory callData) internal {
        vm.prank(agent);
        account.executeAsSession(address(gate), abi.encodeCall(gate.submit, (target, callData, new SignedReading[](0))));
    }

    function _logged(Vm.Log[] memory logs, bytes32 topic) internal view returns (bool) {
        for (uint256 i = 0; i < logs.length; ++i) {
            if (logs[i].emitter == address(gate) && logs[i].topics[0] == topic) return true;
        }
        return false;
    }
}
