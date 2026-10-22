// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import {Vm} from "forge-std/Test.sol";
import {console} from "forge-std/console.sol";
import {PolicyFixture} from "../policies/PolicyFixture.sol";
import {PolicyGate} from "../../contracts/gate/PolicyGate.sol";
import {DecoderRegistry} from "../../contracts/gate/DecoderRegistry.sol";
import {SessionBreaker} from "../../contracts/gate/SessionBreaker.sol";
import {WindowLib} from "../../contracts/policies/WindowLib.sol";
import {LockableERC1155} from "../../contracts/market/LockableERC1155.sol";
import {PaymentTokenDecoder} from "../../contracts/market/PaymentTokenDecoder.sol";
import {IERC1155} from "@openzeppelin/contracts/token/ERC1155/IERC1155.sol";
import {MockEnergyMarket} from "./mocks/MockEnergyMarket.sol";
import {CallKind} from "../../contracts/gate/GateTypes.sol";
import {SignedReading} from "../../contracts/oracle/OracleTypes.sol";

/// @notice A9, the recipient lock (spec v0.2 section 11.2): a funds move must
///         pay the account, an approval must name a market of the account, and
///         a call that can move funds without a decodable recipient cannot be
///         registered. On the mock market's `withdraw` and on the market token.
contract RecipientLockTest is PolicyFixture {
    LockableERC1155 internal token;
    PaymentTokenDecoder internal tokenDecoder;
    address internal stranger = makeAddr("stranger");

    function setUp() public override {
        super.setUp();
        token = new LockableERC1155("ENERGY_MARKET", "");
        tokenDecoder = new PaymentTokenDecoder();
        _asAccount(abi.encodeCall(gate.setDecoder, (address(market), MockEnergyMarket.withdraw.selector, decoder)));
        bytes4[3] memory tokenCalls = [
            LockableERC1155.setPaymentAllowance.selector,
            IERC1155.setApprovalForAll.selector,
            IERC1155.safeTransferFrom.selector
        ];
        for (uint256 i = 0; i < tokenCalls.length; ++i) {
            _asAccount(abi.encodeCall(gate.setDecoder, (address(token), tokenCalls[i], tokenDecoder)));
        }
    }

    function _submitTo(address target, bytes memory callData) internal returns (Vm.Log[] memory logs) {
        vm.recordLogs();
        vm.prank(agent);
        account.executeAsSession(address(gate), abi.encodeCall(gate.submit, (target, callData, new SignedReading[](0))));
        logs = vm.getRecordedLogs();
    }

    function _withdraw(address to, uint256 amount) internal returns (Vm.Log[] memory) {
        return _submitTo(address(market), abi.encodeCall(MockEnergyMarket.withdraw, (to, amount)));
    }

    function _has(Vm.Log[] memory logs, bytes32 topic) internal view returns (bool) {
        for (uint256 i = 0; i < logs.length; ++i) {
            if (logs[i].emitter == address(gate) && logs[i].topics[0] == topic) return true;
        }
        return false;
    }

    // ------------------------------------------------------------------
    // Funds moves: the recipient must be the account
    // ------------------------------------------------------------------

    function test_aWithdrawalToTheAgentIsRefused() public {
        Vm.Log[] memory logs = _withdraw(agent, 1_000);
        assertEq(market.withdrawn(address(account), agent), 0, "nothing paid");
        assertTrue(_has(logs, PolicyGate.RecipientRefused.selector));
        assertTrue(_has(logs, PolicyGate.Rejected.selector));
        assertFalse(_has(logs, PolicyGate.Executed.selector));
    }

    function test_aWithdrawalToAStrangerIsRefused() public {
        _withdraw(stranger, 1_000);
        assertEq(market.withdrawn(address(account), stranger), 0);
    }

    function test_aWithdrawalToTheAccountPasses() public {
        Vm.Log[] memory logs = _withdraw(address(account), 1_000);
        assertEq(market.withdrawn(address(account), address(account)), 1_000);
        assertTrue(_has(logs, PolicyGate.FundsMoved.selector));
        assertTrue(_has(logs, PolicyGate.Executed.selector));
    }

    /// @dev The recipient is compared with the account, not with whoever
    ///      called: the agent's session makes the account the caller.
    function test_theRefusalNamesWhatWasAsked() public {
        Vm.Log[] memory logs = _withdraw(agent, 7);
        for (uint256 i = 0; i < logs.length; ++i) {
            if (logs[i].topics[0] != PolicyGate.RecipientRefused.selector) continue;
            assertEq(logs[i].topics[3], bytes32(uint256(uint160(address(market)))));
            (CallKind kind, address counterparty, uint256 amount) = abi.decode(logs[i].data, (CallKind, address, uint256));
            assertEq(uint8(kind), uint8(CallKind.FUNDS_MOVE));
            assertEq(counterparty, agent);
            assertEq(amount, 7);
        }
    }

    function test_aTokenTransferToTheAgentIsRefused() public {
        bytes memory transfer = abi.encodeCall(IERC1155.safeTransferFrom, (address(account), agent, 0, 5, bytes("")));
        Vm.Log[] memory logs = _submitTo(address(token), transfer);
        assertTrue(_has(logs, PolicyGate.RecipientRefused.selector));
    }

    /// @dev Spec section 7 adds G1: a refused move counts as a rejection.
    function test_aRefusedMoveCountsTowardG1() public {
        WindowLib.Config memory w = WindowLib.Config({
            kind: WindowLib.Kind.SLIDING, step: 300, buckets: 12, anchor: 0, cap: 0, rate: 0, initial: 0
        });
        WindowLib.Config memory f = WindowLib.Config({
            kind: WindowLib.Kind.SLIDING, step: 3600, buckets: 24, anchor: 0, cap: 30, rate: 0, initial: 0
        });
        _asAccount(
            abi.encodeCall(
                gate.setBreakerConfig, (abi.encode(SessionBreaker.Config({rejects: w, flags: f, cooldownSeconds: 0})))
            )
        );
        _withdraw(agent, 1);
        SessionBreaker breaker = gate.breaker();
        assertTrue(breaker.stateOf(address(account), gate.generationOf(address(account))).suspended);

        // Suspended: even a withdrawal to the account waits for the owner.
        Vm.Log[] memory logs = _withdraw(address(account), 1);
        assertTrue(_has(logs, PolicyGate.SuspendedRefusal.selector));
        assertEq(market.withdrawn(address(account), address(account)), 0);
    }

    // ------------------------------------------------------------------
    // Approvals: the spender must be a market of the account
    // ------------------------------------------------------------------

    function test_anAllowanceForARegisteredMarketPasses() public {
        _submitTo(address(token), abi.encodeCall(LockableERC1155.setPaymentAllowance, (address(market), 500)));
        assertEq(token.paymentAllowance(address(account), address(market)), 500);
    }

    function test_anAllowanceForAnyoneElseIsRefused() public {
        Vm.Log[] memory logs =
            _submitTo(address(token), abi.encodeCall(LockableERC1155.setPaymentAllowance, (agent, type(uint256).max)));
        assertEq(token.paymentAllowance(address(account), agent), 0);
        assertTrue(_has(logs, PolicyGate.RecipientRefused.selector));
    }

    function test_anApprovalForAllToAnyoneElseIsRefused() public {
        _submitTo(address(token), abi.encodeCall(IERC1155.setApprovalForAll, (agent, true)));
        assertFalse(token.isApprovedForAll(address(account), agent));
        _submitTo(address(token), abi.encodeCall(IERC1155.setApprovalForAll, (address(market), true)));
        assertTrue(token.isApprovedForAll(address(account), address(market)));
    }

    /// @dev A target is a market while it has an order call registered. With
    ///      its three order calls withdrawn, an approval for it is refused, and
    ///      re-registering one makes it a market again.
    function test_withdrawingTheOrderCallsEndsTheMarket() public {
        assertTrue(gate.isMarket(address(account), address(market)));
        bytes4[3] memory orderCalls = [
            MockEnergyMarket.placeOrder.selector,
            MockEnergyMarket.cancelOrder.selector,
            MockEnergyMarket.modifyOrder.selector
        ];
        for (uint256 i = 0; i < 3; ++i) {
            assertTrue(gate.isMarket(address(account), address(market)), "still a market");
            _asAccount(abi.encodeCall(gate.removeDecoder, (address(market), orderCalls[i])));
        }
        assertFalse(gate.isMarket(address(account), address(market)), "withdraw alone is no market");
        _submitTo(address(token), abi.encodeCall(LockableERC1155.setPaymentAllowance, (address(market), 500)));
        assertEq(token.paymentAllowance(address(account), address(market)), 0);

        _asAccount(abi.encodeCall(gate.setDecoder, (address(market), orderCalls[0], decoder)));
        assertTrue(gate.isMarket(address(account), address(market)));
    }

    /// @dev Registering the same order call twice counts it once.
    function test_aMarketIsCountedByCallNotByRegistration() public {
        _asAccount(abi.encodeCall(gate.setDecoder, (address(market), MockEnergyMarket.placeOrder.selector, decoder)));
        _asAccount(abi.encodeCall(gate.removeDecoder, (address(market), MockEnergyMarket.placeOrder.selector)));
        _asAccount(abi.encodeCall(gate.removeDecoder, (address(market), MockEnergyMarket.cancelOrder.selector)));
        assertTrue(gate.isMarket(address(account), address(market)), "modifyOrder is still registered");
        _asAccount(abi.encodeCall(gate.removeDecoder, (address(market), MockEnergyMarket.modifyOrder.selector)));
        assertFalse(gate.isMarket(address(account), address(market)));
    }

    // ------------------------------------------------------------------
    // Registration
    // ------------------------------------------------------------------

    /// @dev `lock` names an unlocker who may later pay the locked funds to
    ///      anyone: a funds move whose recipient cannot be decoded.
    function test_aFundsMoveWithoutADecodableRecipientCannotBeRegistered() public {
        vm.expectRevert(
            abi.encodeWithSelector(
                DecoderRegistry.DecoderRegistry_UnregistrableCall.selector,
                address(token),
                LockableERC1155.lock.selector,
                CallKind.OPAQUE_FUNDS_MOVE
            )
        );
        vm.prank(owner);
        account.execute(address(gate), 0, abi.encodeCall(gate.setDecoder, (address(token), LockableERC1155.lock.selector, tokenDecoder)));
    }

    function test_aCallTheDecoderDoesNotKnowCannotBeRegistered() public {
        bytes4[3] memory unknown = [
            LockableERC1155.burnEnergy.selector, LockableERC1155.mintPayment.selector, MockEnergyMarket.fill.selector
        ];
        address[3] memory targets = [address(token), address(token), address(market)];
        address[3] memory decoders = [address(tokenDecoder), address(tokenDecoder), address(decoder)];
        for (uint256 i = 0; i < 3; ++i) {
            vm.expectRevert(
                abi.encodeWithSelector(
                    DecoderRegistry.DecoderRegistry_UnregistrableCall.selector, targets[i], unknown[i], CallKind.UNKNOWN
                )
            );
            vm.prank(owner);
            account.execute(address(gate), 0, abi.encodeCall(gate.setDecoder, (targets[i], unknown[i], PaymentTokenDecoder(decoders[i]))));
        }
    }

    function test_theRegisteredKindIsKept() public view {
        assertEq(uint8(gate.kindOf(address(account), address(market), MockEnergyMarket.placeOrder.selector)), uint8(CallKind.ORDER));
        assertEq(uint8(gate.kindOf(address(account), address(market), MockEnergyMarket.cancelOrder.selector)), uint8(CallKind.CANCEL));
        assertEq(uint8(gate.kindOf(address(account), address(market), MockEnergyMarket.withdraw.selector)), uint8(CallKind.FUNDS_MOVE));
        assertEq(
            uint8(gate.kindOf(address(account), address(token), LockableERC1155.setPaymentAllowance.selector)),
            uint8(CallKind.APPROVAL)
        );
        assertFalse(gate.isMarket(address(account), address(token)), "a token is no market");
    }

    /// @dev Gas of a withdrawal through the gate: to the account (made), and
    ///      to the agent (refused), after one of each to warm the storage.
    function test_gas_A9() public {
        _withdraw(address(account), 1);
        _withdraw(agent, 1);
        bytes memory toAccount = abi.encodeCall(MockEnergyMarket.withdraw, (address(account), 1));
        bytes memory toAgent = abi.encodeCall(MockEnergyMarket.withdraw, (agent, 1));
        console.log("A9 withdrawal to the account, made:", _gasOf(toAccount));
        console.log("A9 withdrawal to the agent, refused:", _gasOf(toAgent));
    }

    function _gasOf(bytes memory callData) internal returns (uint256 used) {
        bytes memory sub = abi.encodeCall(gate.submit, (address(market), callData, new SignedReading[](0)));
        vm.prank(agent);
        uint256 before = gasleft();
        account.executeAsSession(address(gate), sub);
        used = before - gasleft();
    }

    // ------------------------------------------------------------------
    // The token decoder, call by call
    // ------------------------------------------------------------------

    function test_theTokenDecoderExposesEveryRecipient() public view {
        uint256[] memory ids = new uint256[](2);
        uint256[] memory values = new uint256[](2);
        values[0] = 3;
        values[1] = 4;
        (address to, uint256 amount) = tokenDecoder.fundsMove(
            address(token), abi.encodeCall(IERC1155.safeBatchTransferFrom, (address(account), agent, ids, values, bytes("")))
        );
        assertEq(to, agent);
        assertEq(amount, 7);

        (to, amount) = tokenDecoder.fundsMove(
            address(token), abi.encodeCall(LockableERC1155.unlock, (address(account), stranger, 9, address(0)))
        );
        assertEq(to, address(account), "no recipient: back to the owner");
        assertEq(amount, 9);
        (to,) = tokenDecoder.fundsMove(address(token), abi.encodeCall(LockableERC1155.unlock, (address(account), stranger, 9, agent)));
        assertEq(to, agent);
        (to,) = tokenDecoder.fundsMove(address(token), abi.encodeCall(LockableERC1155.unlockAll, (stranger, agent)));
        assertEq(to, stranger, "unlockAll returns to the owner");

        (to, amount) = tokenDecoder.fundsMove(address(token), abi.encodeCall(IERC1155.setApprovalForAll, (agent, false)));
        assertEq(to, agent);
        assertEq(amount, 0);
    }
}
