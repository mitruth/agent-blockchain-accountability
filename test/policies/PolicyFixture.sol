// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import {Test, Vm} from "forge-std/Test.sol";
import {PolicyGate} from "../../contracts/gate/PolicyGate.sol";
import {PositionLedger} from "../../contracts/gate/PositionLedger.sol";
import {IPolicy} from "../../contracts/interfaces/IPolicy.sol";
import {Side, CheckResult} from "../../contracts/gate/GateTypes.sol";
import {MiniAccount} from "../../contracts/harness/MiniAccount.sol";
import {MockEnergyMarket} from "../gate/mocks/MockEnergyMarket.sol";
import {MockMarketDecoder} from "../gate/mocks/MockMarketDecoder.sol";
import {SignedReading} from "../../contracts/oracle/OracleTypes.sol";
import {OracleVerifier} from "../../contracts/oracle/OracleVerifier.sol";

/// @notice One account with the gate installed, an agent with a session, and
///         the mock market's three order functions approved. Policies are
///         added by each test.
///
/// Time: genesis is 09:00 UTC; slots are 30 minutes; trading in a slot closes
/// one hour before it starts. Slot 10 starts at 14:00 UTC, five hours after
/// genesis.
abstract contract PolicyFixture is Test {
    uint256 internal constant EXECUTOR = 2;
    uint64 internal constant GENESIS = 1_760_000_400;
    uint32 internal constant SLOT_SECONDS = 1800;
    uint32 internal constant GATE_LEAD = 3600;
    uint32 internal constant SLOT = 10;
    uint64 internal constant PRICE = 250_000;

    PositionLedger internal ledger;
    PolicyGate internal gate;
    MiniAccount internal account;
    MockEnergyMarket internal market;
    MockMarketDecoder internal decoder;

    address internal owner = makeAddr("owner");
    address internal agent = makeAddr("agent");
    address internal operator = makeAddr("clearingEngine");
    address internal keeper = makeAddr("keeper");

    function setUp() public virtual {
        vm.warp(GENESIS);
        ledger = new PositionLedger();
        gate = new PolicyGate(ledger, new OracleVerifier(), 48);
        account = new MiniAccount(owner);
        market = new MockEnergyMarket(GENESIS, SLOT_SECONDS, GATE_LEAD, operator);
        decoder = new MockMarketDecoder();

        vm.startPrank(owner);
        account.installModule(EXECUTOR, address(gate), "");
        account.execute(address(ledger), 0, abi.encodeCall(ledger.setWriter, (address(gate), true)));
        account.enableSession(agent, address(gate), PolicyGate.submit.selector, type(uint48).max);
        bytes4[3] memory selectors = [
            MockEnergyMarket.placeOrder.selector,
            MockEnergyMarket.cancelOrder.selector,
            MockEnergyMarket.modifyOrder.selector
        ];
        for (uint256 i = 0; i < selectors.length; ++i) {
            account.execute(address(gate), 0, abi.encodeCall(gate.setDecoder, (address(market), selectors[i], decoder)));
        }
        vm.stopPrank();
    }

    // --- the owner path ---------------------------------------------------

    function _asAccount(bytes memory gateCall) internal {
        vm.prank(owner);
        account.execute(address(gate), 0, gateCall);
    }

    function _addPolicy(IPolicy policy, bytes32 id, bytes memory config) internal {
        _asAccount(abi.encodeCall(gate.addPolicy, (policy, id, config)));
    }

    // --- the agent's path ---------------------------------------------------

    function _submit(bytes memory marketCall) internal returns (bytes32) {
        vm.prank(agent);
        bytes memory result =
            account.executeAsSession(address(gate), abi.encodeCall(gate.submit, (address(market), marketCall, new SignedReading[](0))));
        return result.length == 32 ? abi.decode(result, (bytes32)) : bytes32(0);
    }

    function _placeCall(Side side, uint32 slot, uint64 qtyWh, uint64 price) internal pure returns (bytes memory) {
        return abi.encodeCall(MockEnergyMarket.placeOrder, (side, slot, qtyWh, price));
    }

    /// @dev Place through the gate; returns the new order's id, or zero if the
    ///      submission was rejected.
    function _place(Side side, uint32 slot, uint64 qtyWh, uint64 price) internal returns (bytes32) {
        uint256 before = market.orderCount();
        _submit(_placeCall(side, slot, qtyWh, price));
        return market.orderCount() > before ? bytes32(market.orderCount()) : bytes32(0);
    }

    function _cancel(bytes32 orderId) internal {
        _submit(abi.encodeCall(MockEnergyMarket.cancelOrder, (orderId)));
    }

    function _reconcile(bytes32 orderId) internal {
        vm.prank(keeper);
        gate.reconcile(address(account), address(market), orderId);
    }

    /// @dev The results the gate logged for one policy, in order, from logs
    ///      recorded since `vm.recordLogs()`.
    function _resultsFor(Vm.Log[] memory logs, address policy) internal view returns (CheckResult[] memory out) {
        uint256 n;
        for (uint256 i = 0; i < logs.length; ++i) {
            if (_isResult(logs[i], policy)) n++;
        }
        out = new CheckResult[](n);
        n = 0;
        for (uint256 i = 0; i < logs.length; ++i) {
            if (!_isResult(logs[i], policy)) continue;
            (, out[n++]) = abi.decode(logs[i].data, (bytes32, CheckResult));
        }
    }

    function _isResult(Vm.Log memory log, address policy) private view returns (bool) {
        return log.emitter == address(gate) && log.topics[0] == PolicyGate.PolicyResult.selector
            && log.topics[3] == bytes32(uint256(uint160(policy)));
    }
}
