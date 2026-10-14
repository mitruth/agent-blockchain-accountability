// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import {Test} from "forge-std/Test.sol";
import {PositionLedger} from "../../contracts/gate/PositionLedger.sol";
import {IOrderDecoder} from "../../contracts/interfaces/IOrderDecoder.sol";
import {Order, OrderKind, Side, FillState} from "../../contracts/gate/GateTypes.sol";

/// @notice A decoder whose reported fill the test sets directly, including
///         fills no honest market would report.
contract ScriptedDecoder is IOrderDecoder {
    uint64 public filledWh;
    bool public open = true;

    function setFill(uint64 filledWh_, bool open_) external {
        filledWh = filledWh_;
        open = open_;
    }

    function decode(address, bytes calldata) external pure override returns (Order[] memory legs) {}

    function placedOrderIds(address, bytes calldata, bytes calldata)
        external
        pure
        override
        returns (bytes32[] memory)
    {}

    function fillState(address, bytes32) external view override returns (FillState memory state) {
        state.filledWh = filledWh;
        state.open = open;
    }

    function gateTime(address, uint32) external pure override returns (uint64) {
        return type(uint64).max;
    }
}

/// The position ledger on its own, written by a test address the account has
/// appointed. These are the rules the order-lifecycle tests reach only
/// indirectly: what the ledger refuses to book, and who may write it.
contract PositionLedgerTest is Test {
    PositionLedger internal ledger;
    ScriptedDecoder internal decoder;

    address internal account = makeAddr("account");
    address internal writer = makeAddr("writer");
    address internal market = makeAddr("market");
    bytes32 internal constant ID = bytes32(uint256(1));

    function setUp() public {
        ledger = new PositionLedger();
        decoder = new ScriptedDecoder();
        vm.prank(account);
        ledger.setWriter(writer, true);
    }

    function _leg(OrderKind kind, uint64 qtyWh) internal pure returns (Order memory leg) {
        leg.kind = kind;
        leg.side = Side.BUY;
        leg.slot = 7;
        leg.qtyWh = qtyWh;
        leg.price = 100;
    }

    function _place(bytes32 orderId, uint64 qtyWh) internal {
        vm.prank(writer);
        ledger.recordPlace(account, market, decoder, orderId, _leg(OrderKind.PLACE, qtyWh));
    }

    function test_theOpenOrderBoundIsSixtyFour() public view {
        assertEq(ledger.MAX_OPEN_ORDERS(), 64);
    }

    function test_anOrderIsBookedOnce() public {
        _place(ID, 1000);

        vm.expectRevert(abi.encodeWithSelector(PositionLedger.PositionLedger_AlreadyRecorded.selector, market, ID));
        _place(ID, 1000);

        assertEq(ledger.positionOf(account, 7).committedBuyWh, 1000);
        assertEq(ledger.openOrderCount(account), 1);
    }

    function test_onlyAPlacementLegIsBookedAsAPlacement() public {
        vm.expectRevert(PositionLedger.PositionLedger_NotAPlacement.selector);
        vm.prank(writer);
        ledger.recordPlace(account, market, decoder, ID, _leg(OrderKind.CANCEL, 1000));
    }

    function test_aZeroQuantityIsNotBooked() public {
        vm.expectRevert(PositionLedger.PositionLedger_ZeroQuantity.selector);
        _place(ID, 0);
    }

    function test_aFillBeyondTheOrderIsRefused() public {
        _place(ID, 1000);
        decoder.setFill(1001, true);

        vm.expectRevert(
            abi.encodeWithSelector(PositionLedger.PositionLedger_InconsistentFill.selector, ID, 0, 1001, 1000)
        );
        vm.prank(writer);
        ledger.reconcile(account, market, ID);
    }

    function test_aFillThatGoesBackwardsIsRefused() public {
        _place(ID, 1000);
        decoder.setFill(600, true);
        vm.prank(writer);
        ledger.reconcile(account, market, ID);

        decoder.setFill(500, true);
        vm.expectRevert(
            abi.encodeWithSelector(PositionLedger.PositionLedger_InconsistentFill.selector, ID, 600, 500, 1000)
        );
        vm.prank(writer);
        ledger.reconcile(account, market, ID);

        assertEq(ledger.positionOf(account, 7).clearedBuyWh, 600);
    }

    function test_aWithdrawnWriterCanNoLongerWrite() public {
        vm.prank(account);
        ledger.setWriter(writer, false);

        assertFalse(ledger.isWriter(account, writer));
        vm.expectRevert(abi.encodeWithSelector(PositionLedger.PositionLedger_NotWriter.selector, account, writer));
        _place(ID, 1000);
    }

    /// Writers are per account: appointed by one account, a writer has no
    /// hold on another.
    function test_aWriterOfOneAccountCannotWriteAnother() public {
        address other = makeAddr("otherAccount");

        vm.expectRevert(abi.encodeWithSelector(PositionLedger.PositionLedger_NotWriter.selector, other, writer));
        vm.prank(writer);
        ledger.recordPlace(other, market, decoder, ID, _leg(OrderKind.PLACE, 1000));
    }
}
