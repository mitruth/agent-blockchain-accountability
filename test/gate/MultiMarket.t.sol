// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import {PolicyFixture} from "../policies/PolicyFixture.sol";
import {OracleFixture} from "../oracle/OracleFixture.sol";
import {PolicyGate} from "../../contracts/gate/PolicyGate.sol";
import {PositionLedger} from "../../contracts/gate/PositionLedger.sol";
import {DecoderRegistry} from "../../contracts/gate/DecoderRegistry.sol";
import {DeliverabilityPolicy} from "../../contracts/policies/DeliverabilityPolicy.sol";
import {RampPolicy} from "../../contracts/policies/RampPolicy.sol";
import {OracleVerifier} from "../../contracts/oracle/OracleVerifier.sol";
import {ReadingKind, SignedReading} from "../../contracts/oracle/OracleTypes.sol";
import {MockEnergyMarket} from "./mocks/MockEnergyMarket.sol";
import {Side, Order, FillState} from "../../contracts/gate/GateTypes.sol";
import {IOrderDecoder} from "../../contracts/interfaces/IOrderDecoder.sol";

/// @notice C4 (spec v0.2): one account trading on two markets. Positions are
///         summed per slot across both, so a policy judges the account's whole
///         position: each venue alone passes, the sum does not. A market on
///         another slot grid -- another length (D15) or another origin -- is
///         refused at registration.
contract MultiMarketTest is PolicyFixture, OracleFixture {
    bytes32 internal constant S3 = keccak256("S3");
    bytes32 internal constant S5 = keccak256("S5");

    MockEnergyMarket internal marketB;

    function setUp() public override {
        super.setUp();
        marketB = new MockEnergyMarket(GENESIS, SLOT_SECONDS, GATE_LEAD, operator);
        _approve(address(marketB));
    }

    function _approve(address target) internal {
        bytes4[3] memory selectors = [
            MockEnergyMarket.placeOrder.selector,
            MockEnergyMarket.cancelOrder.selector,
            MockEnergyMarket.modifyOrder.selector
        ];
        for (uint256 i = 0; i < selectors.length; ++i) {
            _asAccount(abi.encodeCall(gate.setDecoder, (target, selectors[i], decoder)));
        }
    }

    function _submitTo(address target, bytes memory marketCall, SignedReading[] memory readings) internal {
        vm.prank(agent);
        account.executeAsSession(address(gate), abi.encodeCall(gate.submit, (target, marketCall, readings)));
    }

    function _sellOn(MockEnergyMarket venue, uint32 slot, uint64 qtyWh, SignedReading[] memory readings)
        internal
        returns (bool placed)
    {
        uint256 before = venue.orderCount();
        _submitTo(address(venue), _placeCall(Side.SELL, slot, qtyWh, PRICE), readings);
        return venue.orderCount() > before;
    }

    // ------------------------------------------------------------------
    // The grid
    // ------------------------------------------------------------------

    function test_theFirstMarketFixesTheAccountsGrid() public view {
        PositionLedger.Grid memory grid = ledger.gridOf(address(account));
        assertEq(grid.origin, GENESIS);
        assertEq(grid.slotSeconds, SLOT_SECONDS);
    }

    /// @dev D15: a market with another slot length cannot be registered.
    function test_aMarketWithAnotherSlotLengthIsRefused() public {
        MockEnergyMarket hourly = new MockEnergyMarket(GENESIS, 3600, GATE_LEAD, operator);
        vm.expectRevert(
            abi.encodeWithSelector(PositionLedger.PositionLedger_OffGrid.selector, GENESIS, 3600, GENESIS, SLOT_SECONDS)
        );
        vm.prank(owner);
        account.execute(
            address(gate), 0, abi.encodeCall(gate.setDecoder, (address(hourly), MockEnergyMarket.placeOrder.selector, decoder))
        );
    }

    /// @dev Same length, shifted by a quarter of an hour: slot n there is not
    ///      slot n here. Refused (decision of 21 October 2026).
    function test_aMarketWithAnotherOriginIsRefused() public {
        MockEnergyMarket shifted = new MockEnergyMarket(GENESIS + 900, SLOT_SECONDS, GATE_LEAD, operator);
        vm.expectRevert(
            abi.encodeWithSelector(
                PositionLedger.PositionLedger_OffGrid.selector, GENESIS + 900, SLOT_SECONDS, GENESIS, SLOT_SECONDS
            )
        );
        vm.prank(owner);
        account.execute(
            address(gate), 0, abi.encodeCall(gate.setDecoder, (address(shifted), MockEnergyMarket.placeOrder.selector, decoder))
        );
    }

    /// @dev A shift by a whole number of slots is the same grid, numbered
    ///      differently, and still refused: slot numbers must agree.
    function test_aMarketShiftedByWholeSlotsIsRefused() public {
        MockEnergyMarket shifted = new MockEnergyMarket(GENESIS + SLOT_SECONDS, SLOT_SECONDS, GATE_LEAD, operator);
        vm.expectRevert();
        vm.prank(owner);
        account.execute(
            address(gate), 0, abi.encodeCall(gate.setDecoder, (address(shifted), MockEnergyMarket.placeOrder.selector, decoder))
        );
    }

    /// @dev The positions outlive a reinstall of the gate, and so does the grid
    ///      they are numbered on.
    function test_theGridSurvivesAReinstall() public {
        vm.startPrank(owner);
        account.uninstallModule(EXECUTOR, address(gate), "");
        account.installModule(EXECUTOR, address(gate), "");
        MockEnergyMarket hourly = new MockEnergyMarket(GENESIS, 3600, GATE_LEAD, operator);
        vm.expectRevert();
        account.execute(
            address(gate), 0, abi.encodeCall(gate.setDecoder, (address(hourly), MockEnergyMarket.placeOrder.selector, decoder))
        );
        vm.stopPrank();
    }

    /// @dev A decoder whose slots do not advance has no grid to check.
    function test_aMarketWithoutASlotGridIsRefused() public {
        FlatDecoder flat = new FlatDecoder();
        vm.expectRevert(abi.encodeWithSelector(DecoderRegistry.DecoderRegistry_NoSlotGrid.selector, address(marketB)));
        vm.prank(owner);
        account.execute(
            address(gate), 0, abi.encodeCall(gate.setDecoder, (address(marketB), MockEnergyMarket.placeOrder.selector, flat))
        );
    }

    function test_aGridHasASlotLength() public {
        address writer = makeAddr("writer");
        vm.startPrank(writer);
        ledger.setWriter(writer, true);
        vm.expectRevert(PositionLedger.PositionLedger_ZeroSlotLength.selector);
        ledger.fixGrid(writer, 0, 0);
        vm.stopPrank();
    }

    function test_onlyAWriterFixesAGrid() public {
        vm.expectRevert(
            abi.encodeWithSelector(PositionLedger.PositionLedger_NotWriter.selector, address(account), address(this))
        );
        ledger.fixGrid(address(account), 0, 3600);
    }

    // ------------------------------------------------------------------
    // Positions are the account's, across venues
    // ------------------------------------------------------------------

    function test_positionsSumAcrossMarkets() public {
        _sellOn(market, SLOT, 400, new SignedReading[](0));
        _sellOn(marketB, SLOT, 700, new SignedReading[](0));
        assertEq(ledger.positionOf(address(account), SLOT).committedSellWh, 1_100);
    }

    /// @dev S5 at 1,500 Wh a step. 1,000 Wh on either venue alone passes; the
    ///      same 1,000 on the second venue, after the first, makes a 2,000 Wh
    ///      step and is rejected.
    function test_S5_eachVenueAlonePasses() public {
        _addRamp();
        assertTrue(_sellOn(marketB, SLOT, 1_000, new SignedReading[](0)));
    }

    function test_S5_theSumAcrossVenuesIsRejected() public {
        _addRamp();
        assertTrue(_sellOn(market, SLOT, 1_000, new SignedReading[](0)));
        assertFalse(_sellOn(marketB, SLOT, 1_000, new SignedReading[](0)));
        assertEq(ledger.positionOf(address(account), SLOT).committedSellWh, 1_000);
    }

    /// @dev S3 on home_01's battery (5 kWh, 3 kW, 95 %, floor 10 %), 3,000 Wh
    ///      stored. 1,400 Wh in slot 4 on market A and 1,400 Wh in slot 5 on
    ///      market B each fit; both together draw 2,948 Wh of the 2,500 above
    ///      the floor.
    function test_S3_eachVenueAlonePasses() public {
        OracleVerifier oracle = _addS3();
        assertTrue(_sellOn(marketB, 5, 1_400, _battery(oracle, 3_000)));
    }

    function test_S3_theSumAcrossVenuesIsRejected() public {
        OracleVerifier oracle = _addS3();
        assertTrue(_sellOn(market, 4, 1_400, _battery(oracle, 3_000)));
        assertFalse(_sellOn(marketB, 5, 1_400, new SignedReading[](0)));
    }

    // ------------------------------------------------------------------

    function _addRamp() internal {
        RampPolicy s5 = new RampPolicy(address(gate));
        _addPolicy(s5, S5, abi.encode(RampPolicy.Config({softStepWh: 1_000, maxStepWh: 1_500})));
    }

    function _addS3() internal returns (OracleVerifier oracle) {
        oracle = gate.oracle();
        vm.prank(owner);
        account.execute(address(oracle), 0, abi.encodeCall(oracle.setDevice, (ReadingKind.BMS, bmsSigner, SLOT_SECONDS)));
        DeliverabilityPolicy s3 = new DeliverabilityPolicy(address(gate));
        _addPolicy(s3, S3, abi.encode(_s3Config()));
    }

    function _s3Config() internal pure returns (DeliverabilityPolicy.Config memory) {
        return DeliverabilityPolicy.Config({
            horizonSlots: 16,
            capacityWh: 5_000,
            socMinProfileBps: _flat(1_000),
            socMaxBps: 10_000,
            chargePowerW: 3_000,
            dischargePowerW: 3_000,
            etaChargeBps: 9_500,
            etaDischargeBps: 9_500,
            pvCreditBps: 10_000,
            reserveLoadWh: 0
        });
    }

    function _flat(uint16 bps) internal pure returns (uint16[24] memory profile) {
        for (uint256 i = 0; i < 24; ++i) {
            profile[i] = bps;
        }
    }

    function _battery(OracleVerifier oracle, uint64 socWh) internal view returns (SignedReading[] memory one) {
        one = new SignedReading[](1);
        one[0] = _signBms(oracle, BMS_KEY, _bms(address(account), market.slotStart(market.currentSlot()), socWh, 0));
    }
}

/// @notice A decoder whose every slot starts at the same time: no grid.
contract FlatDecoder is IOrderDecoder {
    function decode(address, bytes calldata) external pure override returns (Order[] memory) {}

    function placedOrderIds(address, bytes calldata, bytes calldata) external pure override returns (bytes32[] memory) {}

    function fillState(address, bytes32) external pure override returns (FillState memory) {}

    function gateTime(address, uint32) external pure override returns (uint64) {}

    function slotStart(address, uint32) external pure override returns (uint64) {
        return 1_000;
    }
}
