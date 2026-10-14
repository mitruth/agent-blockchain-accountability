// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {LockableERC1155} from "../../contracts/market/LockableERC1155.sol";
import {MarketManager} from "../../contracts/market/MarketManager.sol";
import {MarketSession} from "../../contracts/market/MarketSession.sol";
import {Prosumer} from "../../contracts/market/Prosumer.sol";
import {ClassicSettlement} from "../../contracts/market/ClassicSettlement.sol";
import {MarketTypes} from "../../contracts/market/MarketTypes.sol";

/// @notice A market with hourly slots, a day-ahead session of 24 slots opening
///         tomorrow and closing an hour before delivery starts, and two
///         prosumers, Alice and Bob, each with 1,000 payment units' worth of
///         tokens (6 decimals) and a sensor.
///
/// Prices are per kWh in payment units: 0.30 real-time, bids around 0.25,
/// offers around 0.20.
abstract contract MarketFixture is Test {
    uint32 internal constant SLOT_SECONDS = 3600;
    uint64 internal constant REAL_TIME_PRICE = 300_000;
    uint256 internal constant FUNDS = 1_000_000_000;

    LockableERC1155 internal token;
    MarketManager internal manager;
    ClassicSettlement internal rule;
    MarketSession internal session;

    address internal operator = makeAddr("operator");
    address internal matcher = makeAddr("matcher");
    address internal alice;
    address internal bob;
    address internal aliceSensor = makeAddr("aliceSensor");
    address internal bobSensor = makeAddr("bobSensor");
    address internal stranger = makeAddr("stranger");

    Prosumer internal aliceP;
    Prosumer internal bobP;

    uint32 internal firstSlot;

    /// @dev Owners are plain addresses here. The gate tests use smart accounts.
    function _owners() internal virtual returns (address, address) {
        return (makeAddr("alice"), makeAddr("bob"));
    }

    function setUp() public virtual {
        vm.warp(1_760_000_400);
        (alice, bob) = _owners();

        vm.startPrank(operator);
        token = new LockableERC1155("ENERGY_MARKET", "");
        rule = new ClassicSettlement();
        manager = new MarketManager(token, SLOT_SECONDS, REAL_TIME_PRICE, rule);
        token.setRegistrar(address(manager));
        token.mintPayment(alice, FUNDS);
        token.mintPayment(bob, FUNDS);
        manager.setMatcher(matcher);
        vm.stopPrank();

        aliceP = new Prosumer(alice, manager);
        bobP = new Prosumer(bob, manager);

        vm.startPrank(operator);
        manager.registerProsumer(address(aliceP), aliceSensor);
        manager.registerProsumer(address(bobP), bobSensor);
        vm.stopPrank();

        _approveProsumer(alice, address(aliceP));
        _approveProsumer(bob, address(bobP));

        session = _openDayAhead();
    }

    /// @dev What the owner does once: let its prosumer contract lock
    ///      collateral and move its energy tokens.
    function _approveProsumer(address owner_, address prosumer) internal virtual {
        vm.startPrank(owner_);
        token.setPaymentAllowance(prosumer, type(uint256).max);
        token.setApprovalForAll(prosumer, true);
        vm.stopPrank();
    }

    /// @dev Tomorrow, 24 hourly slots, closing one hour before the first.
    function _openDayAhead() internal returns (MarketSession) {
        firstSlot = uint32(block.timestamp / SLOT_SECONDS) + 24;
        return _open(MarketTypes.EnergyType.ELECTRICITY, firstSlot, 24);
    }

    function _open(MarketTypes.EnergyType energyType, uint32 first, uint16 count) internal returns (MarketSession s) {
        MarketTypes.SessionConfig memory config = MarketTypes.SessionConfig({
            energyType: energyType,
            firstSlot: first,
            slotCount: count,
            closesAt: uint40(uint256(first) * SLOT_SECONDS - 3600)
        });
        vm.prank(operator);
        s = manager.openSession(config);
    }

    function _req(uint16 slot, uint64 quantity, uint64 price) internal pure returns (MarketTypes.OrderRequest memory) {
        return MarketTypes.OrderRequest({slot: slot, quantity: quantity, price: price});
    }

    function _one(uint16 slot, uint64 quantity, uint64 price)
        internal
        pure
        returns (MarketTypes.OrderRequest[] memory reqs)
    {
        reqs = new MarketTypes.OrderRequest[](1);
        reqs[0] = _req(slot, quantity, price);
    }

    function _bid(uint16 slot, uint64 quantity, uint64 price) internal virtual returns (bytes32) {
        vm.prank(alice);
        return aliceP.placeBids(MarketTypes.EnergyType.ELECTRICITY, _one(slot, quantity, price))[0];
    }

    function _offer(uint16 slot, uint64 quantity, uint64 price) internal virtual returns (bytes32) {
        vm.prank(bob);
        return bobP.placeOffers(MarketTypes.EnergyType.ELECTRICITY, _one(slot, quantity, price))[0];
    }

    function _trade(bytes32 bidId, bytes32 offerId, uint64 quantity, uint64 price) internal {
        MarketTypes.Trade[] memory trades = new MarketTypes.Trade[](1);
        trades[0] = MarketTypes.Trade({bidId: bidId, offerId: offerId, quantity: quantity, price: price});
        vm.prank(matcher);
        session.registerTrades(trades);
    }

    function _close() internal {
        vm.warp(session.config().closesAt);
    }

    function _slotOver(uint16 slot) internal {
        vm.warp(manager.slotStart(firstSlot + slot + 1));
    }
}
