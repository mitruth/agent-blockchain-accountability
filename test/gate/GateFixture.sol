// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import {Test} from "forge-std/Test.sol";
import {PolicyGate} from "../../contracts/gate/PolicyGate.sol";
import {PositionLedger} from "../../contracts/gate/PositionLedger.sol";
import {MiniAccount} from "./mocks/MiniAccount.sol";
import {StubMarket, StubDecoder, CapPolicy} from "./mocks/GateMocks.sol";

/// @notice One account with the gate installed and authorised to write the
///         account's positions, one registered agent, one approved market
///         function and one policy instance.
abstract contract GateFixture is Test {
    uint256 internal constant EXECUTOR = 2;
    bytes32 internal constant POLICY_ID = keccak256("cap");
    uint64 internal constant SOFT = 800;
    uint64 internal constant HARD = 1000;

    PositionLedger internal ledger;
    PolicyGate internal gate;
    MiniAccount internal account;
    StubMarket internal market;
    StubDecoder internal decoder;
    CapPolicy internal policy;

    address internal owner = makeAddr("owner");
    address internal agent = makeAddr("agent");
    address internal stranger = makeAddr("stranger");

    uint48 internal agentValidUntil;

    function setUp() public virtual {
        vm.warp(1_760_000_000);

        ledger = new PositionLedger();
        gate = new PolicyGate(ledger);
        account = new MiniAccount(owner);
        market = new StubMarket();
        decoder = new StubDecoder();
        policy = new CapPolicy(address(gate));

        vm.prank(owner);
        account.installModule(EXECUTOR, address(gate), "");

        vm.prank(owner);
        account.execute(address(ledger), 0, abi.encodeCall(ledger.setWriter, (address(gate), true)));

        agentValidUntil = uint48(block.timestamp + 30 days);
        _asAccount(abi.encodeCall(gate.registerAgent, (agent, agentValidUntil)));
        _asAccount(abi.encodeCall(gate.setDecoder, (address(market), StubMarket.placeOrder.selector, decoder)));
        _asAccount(abi.encodeCall(gate.addPolicy, (policy, POLICY_ID, _caps(SOFT, HARD))));
    }

    /// @dev The owner path: the owner has the account call the gate.
    function _asAccount(bytes memory gateCall) internal returns (bytes memory) {
        vm.prank(owner);
        return account.execute(address(gate), 0, gateCall);
    }

    function _caps(uint64 soft, uint64 hard) internal pure returns (bytes memory) {
        return abi.encode(soft, hard);
    }

    function _order(uint64 qtyWh) internal pure returns (bytes memory) {
        return abi.encodeCall(StubMarket.placeOrder, (0, 100, qtyWh, 250_000));
    }

    function _hardCap() internal view returns (uint64 hard) {
        (,, hard) = policy.caps(address(account), POLICY_ID);
    }

    function _softCap() internal view returns (uint64 soft) {
        (, soft,) = policy.caps(address(account), POLICY_ID);
    }
}
