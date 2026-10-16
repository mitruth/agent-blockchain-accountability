// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import {Test, Vm} from "forge-std/Test.sol";
import {PolicyGate} from "../../contracts/gate/PolicyGate.sol";
import {GateBase} from "../../contracts/gate/GateBase.sol";
import {PositionLedger} from "../../contracts/gate/PositionLedger.sol";
import {IPolicy} from "../../contracts/interfaces/IPolicy.sol";
import {Side, Verdict, CheckResult, Release} from "../../contracts/gate/GateTypes.sol";
import {MiniAccount} from "../../contracts/harness/MiniAccount.sol";
import {MockEnergyMarket} from "./mocks/MockEnergyMarket.sol";
import {MockMarketDecoder} from "./mocks/MockMarketDecoder.sol";
import {QtyPolicy, ReentrantPolicy} from "./mocks/PhaseMocks.sol";
import {SignedReading} from "../../contracts/oracle/OracleTypes.sol";
import {OracleVerifier} from "../../contracts/oracle/OracleVerifier.sol";

/// Step 4.2: the gate's check, commit and credit phases (spec 4.1, steps 4 to
/// 8), with a test-double policy that counts the Wh placed.
///
///   check   every instance sees all the legs of a submission; any REJECT
///           stops it without reverting, and every instance's result is in
///           the log; a FLAG is recorded and the submission goes ahead
///   commit  only when every instance accepted, before the market call
///   credit  released volume goes back to the policies: on a cancellation
///           through the gate, and on reconcile after an expiry
///
/// Time: 30-minute slots, trading in a slot closing one hour before it starts;
/// the tests trade slot 10.
contract PolicyPhasesTest is Test {
    uint256 internal constant EXECUTOR = 2;
    uint64 internal constant GENESIS = 1_760_000_400;
    uint32 internal constant SLOT_SECONDS = 1800;
    uint32 internal constant GATE_LEAD = 3600;
    uint32 internal constant SLOT = 10;
    uint64 internal constant PRICE = 250_000;
    bytes32 internal constant A = keccak256("a");
    bytes32 internal constant B = keccak256("b");

    PositionLedger internal ledger;
    PolicyGate internal gate;
    MiniAccount internal account;
    MockEnergyMarket internal market;
    MockMarketDecoder internal decoder;
    QtyPolicy internal policy;

    address internal owner = makeAddr("owner");
    address internal agent = makeAddr("agent");
    address internal operator = makeAddr("clearingEngine");
    address internal keeper = makeAddr("keeper");

    function setUp() public {
        vm.warp(GENESIS);
        ledger = new PositionLedger();
        gate = new PolicyGate(ledger, new OracleVerifier(), 48);
        account = new MiniAccount(owner);
        market = new MockEnergyMarket(GENESIS, SLOT_SECONDS, GATE_LEAD, operator);
        decoder = new MockMarketDecoder();
        policy = new QtyPolicy(address(gate));

        vm.startPrank(owner);
        account.installModule(EXECUTOR, address(gate), "");
        account.execute(address(ledger), 0, abi.encodeCall(ledger.setWriter, (address(gate), true)));
        account.enableSession(agent, address(gate), PolicyGate.submit.selector, uint48(GENESIS + 30 days));
        bytes4[3] memory selectors = [
            MockEnergyMarket.placeOrder.selector,
            MockEnergyMarket.cancelOrder.selector,
            MockEnergyMarket.modifyOrder.selector
        ];
        for (uint256 i = 0; i < selectors.length; ++i) {
            account.execute(address(gate), 0, abi.encodeCall(gate.setDecoder, (address(market), selectors[i], decoder)));
        }
        vm.stopPrank();

        _addPolicy(policy, A, 800, 1000);
    }

    // ------------------------------------------------------------------
    // Check and commit
    // ------------------------------------------------------------------

    function test_anAcceptedSubmissionIsCommittedThenExecuted() public {
        bytes memory call = _placeCall(500);
        bytes32 orderHash = _hash(0, call);

        vm.expectEmit(true, true, true, true, address(gate));
        emit PolicyGate.PolicyResult(
            address(account),
            orderHash,
            address(policy),
            A,
            CheckResult({valueBefore: 0, valueAfter: 500, soft: 800, hard: 1000, verdict: Verdict.EXECUTE})
        );
        vm.expectEmit(true, true, true, true, address(gate));
        emit PolicyGate.Executed(address(account), orderHash);
        _submit(call);

        assertEq(market.orderCount(), 1);
        assertEq(policy.placedWh(address(account), A), 500);
        assertEq(policy.commits(address(account), A), 1);
        assertEq(ledger.openOrderCount(address(account)), 1);
    }

    function test_aSoftBoundCrossedIsFlaggedAndExecuted() public {
        bytes memory call = _placeCall(900);
        vm.expectEmit(true, true, true, true, address(gate));
        emit PolicyGate.PolicyFlag(address(account), _hash(0, call), address(policy), A, 900, 800);
        _submit(call);

        assertEq(market.orderCount(), 1);
        assertEq(policy.placedWh(address(account), A), 900);
    }

    /// The hard bound is inclusive: exactly at it is a flag, one Wh over is a
    /// rejection.
    function test_theHardBoundIsInclusive() public {
        _submit(_placeCall(1000));
        assertEq(market.orderCount(), 1);
        _submit(_placeCall(1));
        assertEq(market.orderCount(), 1);
    }

    /// A rejection is not a revert. The call returns, the refusal and every
    /// result are in the log, and nothing is committed, booked or sent.
    function test_aRejectedSubmissionReturnsAndLeavesNothingBehind() public {
        _submit(_placeCall(900));
        bytes memory call = _placeCall(200);
        bytes32 orderHash = _hash(1, call);

        vm.expectEmit(true, true, true, true, address(gate));
        emit PolicyGate.PolicyResult(
            address(account),
            orderHash,
            address(policy),
            A,
            CheckResult({valueBefore: 900, valueAfter: 1100, soft: 800, hard: 1000, verdict: Verdict.REJECT})
        );
        vm.expectEmit(true, true, true, true, address(gate));
        emit PolicyGate.Rejected(address(account), orderHash);
        bytes32 returned = _submit(call);

        assertEq(returned, orderHash, "the call returned normally");
        assertEq(market.orderCount(), 1, "the market never saw it");
        assertEq(ledger.openOrderCount(address(account)), 1, "nothing booked");
        assertEq(policy.placedWh(address(account), A), 900, "nothing committed");
        assertEq(policy.commits(address(account), A), 1);
    }

    /// One instance's rejection stops every instance, and every instance's
    /// result is still in the log.
    function test_aRejectionByOneInstanceStopsAllAndEveryResultIsLogged() public {
        _addPolicy(policy, B, 10_000, 20_000);

        vm.recordLogs();
        _submit(_placeCall(1500));
        Vm.Log[] memory logs = vm.getRecordedLogs();

        uint256 results;
        bool rejected;
        for (uint256 i = 0; i < logs.length; ++i) {
            if (logs[i].emitter != address(gate)) continue;
            if (logs[i].topics[0] == PolicyGate.PolicyResult.selector) results++;
            if (logs[i].topics[0] == PolicyGate.Rejected.selector) rejected = true;
        }
        assertEq(results, 2, "both instances reported");
        assertTrue(rejected);
        assertEq(policy.commits(address(account), B), 0, "the accepting instance did not commit either");
        assertEq(market.orderCount(), 0);
    }

    function test_theOwnersOwnSubmissionIsCheckedToo() public {
        vm.expectEmit(true, false, false, false, address(gate));
        emit PolicyGate.Rejected(address(account), bytes32(0));
        vm.prank(owner);
        account.execute(address(gate), 0, abi.encodeCall(gate.submit, (address(market), _placeCall(1500), new SignedReading[](0))));
        assertEq(market.orderCount(), 0);
    }

    function test_aRevertingCheckRevertsTheSubmission() public {
        policy.breakAt(true, false, false);
        vm.expectRevert(QtyPolicy.QtyPolicy_Broken.selector);
        _submit(_placeCall(500));
        assertEq(market.orderCount(), 0);
    }

    function test_aRevertingCommitRevertsTheSubmission() public {
        policy.breakAt(false, true, false);
        vm.expectRevert(QtyPolicy.QtyPolicy_Broken.selector);
        _submit(_placeCall(500));
        assertEq(market.orderCount(), 0);
        assertEq(ledger.openOrderCount(address(account)), 0);
    }

    /// A policy is called during the commit phase, in the middle of a
    /// submission. If it could reconcile an order there, it would release
    /// volume half-way through. The lock refuses it, and the submission fails.
    function test_aPolicyCannotReconcileWhileTheGateCommits() public {
        bytes32 placed = _place(500);
        ReentrantPolicy hostile = new ReentrantPolicy(gate);
        hostile.aim(address(account), address(market), placed);
        _addPolicy(IPolicy(address(hostile)), B, 0, 0);

        vm.expectRevert(GateBase.Gate_Reentrancy.selector);
        _submit(_placeCall(100));
    }

    // ------------------------------------------------------------------
    // Credits
    // ------------------------------------------------------------------

    /// A cancellation only reduces exposure: it passes even at the hard bound
    /// (spec D10), and the cancelled volume is credited back.
    function test_aCancellationAtTheHardBoundPassesAndIsCredited() public {
        bytes32 orderId = _place(1000);
        uint48 placedAt = uint48(block.timestamp);
        vm.warp(block.timestamp + 60);

        _submit(abi.encodeCall(MockEnergyMarket.cancelOrder, (orderId)));

        assertFalse(market.isOpen(orderId));
        assertEq(policy.placedWh(address(account), A), 0);
        Release memory r = policy.lastRelease();
        assertEq(r.market, address(market));
        assertEq(r.orderId, orderId);
        assertEq(uint8(r.side), uint8(Side.BUY));
        assertEq(r.slot, SLOT);
        assertEq(r.placedAt, placedAt, "the placement time, for the window bucket");
        assertEq(r.qtyWh, 1000);
        assertEq(r.price, PRICE);
        assertEq(r.filledWh, 0);
        assertEq(r.releasedWh, 1000);
    }

    function test_aPartlyFilledCancellationCreditsOnlyTheUnfilledPart() public {
        bytes32 orderId = _place(600);
        vm.prank(operator);
        market.fill(orderId, 200, PRICE);

        _submit(abi.encodeCall(MockEnergyMarket.cancelOrder, (orderId)));

        assertEq(policy.placedWh(address(account), A), 200);
        Release memory r = policy.lastRelease();
        assertEq(r.filledWh, 200);
        assertEq(r.releasedWh, 400);
    }

    function test_anExpiryIsCreditedOnReconcile() public {
        bytes32 orderId = _place(600);
        vm.warp(market.gateTime(SLOT));

        vm.prank(keeper);
        gate.reconcile(address(account), address(market), orderId);

        assertEq(policy.placedWh(address(account), A), 0);
        assertEq(policy.lastRelease().releasedWh, 600);
    }

    function test_nothingIsCreditedWhileAnOrderIsStillOpen() public {
        bytes32 orderId = _place(600);
        vm.prank(operator);
        market.fill(orderId, 100, PRICE);

        vm.prank(keeper);
        gate.reconcile(address(account), address(market), orderId);

        assertEq(policy.placedWh(address(account), A), 600);
    }

    /// A broken policy cannot hold reconciliation hostage. Its credit fails,
    /// it keeps the charge, and the order is closed in the ledger anyway.
    function test_aFailingCreditDoesNotBlockReconciliation() public {
        bytes32 orderId = _place(600);
        policy.breakAt(false, false, true);
        vm.warp(market.gateTime(SLOT));

        vm.expectEmit(true, true, true, true, address(gate));
        emit PolicyGate.CreditFailed(address(account), address(policy), A, address(market), orderId);
        vm.prank(keeper);
        gate.reconcile(address(account), address(market), orderId);

        assertEq(policy.placedWh(address(account), A), 600, "the charge stays");
        assertEq(ledger.openOrderCount(address(account)), 0, "the order is closed");
    }

    /// A modification is a cancellation and a placement. The new order is
    /// checked before the old one is credited, so it needs room of its own;
    /// once the market has taken it, the old order's volume comes back.
    function test_aModificationNeedsRoomForTheNewOrderBeforeTheOldIsCredited() public {
        bytes32 orderId = _place(600);

        // 600 + 500 > 1000: refused, although the result would be 500.
        _submit(abi.encodeCall(MockEnergyMarket.modifyOrder, (orderId, SLOT, 500, PRICE)));
        assertTrue(market.isOpen(orderId), "refused: the old order stands");
        assertEq(policy.placedWh(address(account), A), 600);

        // 600 + 300 fits: placed, then the old 600 credited.
        _submit(abi.encodeCall(MockEnergyMarket.modifyOrder, (orderId, SLOT, 300, PRICE)));
        assertFalse(market.isOpen(orderId));
        assertEq(policy.placedWh(address(account), A), 300);
    }

    // ------------------------------------------------------------------
    // Helpers
    // ------------------------------------------------------------------

    function _addPolicy(IPolicy p, bytes32 id, uint64 soft, uint64 hard) internal {
        vm.prank(owner);
        account.execute(address(gate), 0, abi.encodeCall(gate.addPolicy, (p, id, abi.encode(soft, hard))));
    }

    function _placeCall(uint64 qtyWh) internal pure returns (bytes memory) {
        return abi.encodeCall(MockEnergyMarket.placeOrder, (Side.BUY, SLOT, qtyWh, PRICE));
    }

    function _place(uint64 qtyWh) internal returns (bytes32) {
        _submit(_placeCall(qtyWh));
        return bytes32(market.orderCount());
    }

    function _submit(bytes memory marketCall) internal returns (bytes32) {
        vm.prank(agent);
        bytes memory result =
            account.executeAsSession(address(gate), abi.encodeCall(gate.submit, (address(market), marketCall, new SignedReading[](0))));
        return result.length == 32 ? abi.decode(result, (bytes32)) : bytes32(0);
    }

    function _hash(uint256 n, bytes memory call) internal view returns (bytes32) {
        return keccak256(abi.encode(block.chainid, address(gate), address(account), n, address(market), keccak256(call)));
    }
}
