// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import {IOrderDecoder} from "../../../contracts/interfaces/IOrderDecoder.sol";
import {IPolicy} from "../../../contracts/interfaces/IPolicy.sol";
import {PolicyGate} from "../../../contracts/gate/PolicyGate.sol";
import {Order, OrderKind, Side, ConfigChange, FillState} from "../../../contracts/gate/GateTypes.sol";

/// @notice A stand-in market for the key-model tests: it records who called.
///         The real mock market, with a book, gate closure and fills, is
///         contracts/market/MockEnergyMarket.sol.
contract StubMarket {
    address public lastCaller;
    uint256 public orderCount;
    uint256 public withdrawals;

    error StubMarket_ZeroQuantity();

    function placeOrder(uint8, uint32, uint64 qtyWh, uint64) external returns (uint256) {
        if (qtyWh == 0) revert StubMarket_ZeroQuantity();
        lastCaller = msg.sender;
        return ++orderCount;
    }

    /// @dev Exists so the tests have a function the owner never approved.
    function withdrawAll() external {
        lastCaller = msg.sender;
        ++withdrawals;
    }
}

/// @notice Reads `StubMarket.placeOrder` as one placement leg. The market
///         returns a running count, used as the order id.
contract StubDecoder is IOrderDecoder {
    function decode(address, bytes calldata callData) external pure override returns (Order[] memory legs) {
        (uint8 side, uint32 slot, uint64 qtyWh, uint64 price) =
            abi.decode(callData[4:], (uint8, uint32, uint64, uint64));

        legs = new Order[](1);
        legs[0].kind = OrderKind.PLACE;
        legs[0].side = Side(side);
        legs[0].slot = slot;
        legs[0].qtyWh = qtyWh;
        legs[0].price = price;
        // Price is per kWh; a cap quantity rounds up (D12).
        legs[0].value = uint64((uint256(qtyWh) * price + 999) / 1000);
    }

    function placedOrderId(address, bytes calldata, bytes calldata result) external pure override returns (bytes32) {
        return bytes32(abi.decode(result, (uint256)));
    }

    /// @dev Nothing ever fills on the stub market.
    function fillState(address, bytes32) external pure override returns (FillState memory state) {
        state.open = true;
    }

    function gateTime(address, uint32) external pure override returns (uint64) {
        return type(uint64).max;
    }
}

/// @notice A decoder that reads every call as the wrong number of legs.
contract LeglessDecoder is IOrderDecoder {
    uint256 public immutable legCount;

    constructor(uint256 legCount_) {
        legCount = legCount_;
    }

    /// @dev Returns `legCount` placement legs: zero or three, both refused.
    function decode(address, bytes calldata) external view override returns (Order[] memory legs) {
        legs = new Order[](legCount);
        for (uint256 i = 0; i < legCount; ++i) {
            legs[i].kind = OrderKind.PLACE;
            legs[i].qtyWh = 1;
        }
    }

    function placedOrderId(address, bytes calldata, bytes calldata) external pure override returns (bytes32) {}

    function fillState(address, bytes32) external pure override returns (FillState memory state) {}

    function gateTime(address, uint32) external pure override returns (uint64) {}
}

/// @notice Accepts any calldata and reads it as a placement of 1 Wh, with an
///         id derived from the call. For targets that are not markets at all:
///         since every approved call must be an order, the attack tests need a
///         decoder that says it is one.
contract NullDecoder is IOrderDecoder {
    function decode(address, bytes calldata) external pure override returns (Order[] memory legs) {
        legs = new Order[](1);
        legs[0].kind = OrderKind.PLACE;
        legs[0].qtyWh = 1;
        legs[0].price = 1;
        legs[0].value = 1;
    }

    function placedOrderId(address target, bytes calldata callData, bytes calldata)
        external
        pure
        override
        returns (bytes32)
    {
        return keccak256(abi.encode(target, callData));
    }

    function fillState(address, bytes32) external pure override returns (FillState memory state) {
        state.open = true;
    }

    function gateTime(address, uint32) external pure override returns (uint64) {
        return type(uint64).max;
    }
}

/// @notice A policy with two caps, soft and hard, where lower is tighter.
///         Enough to exercise every branch of ConfigManager.
contract CapPolicy is IPolicy {
    struct Caps {
        bool set;
        uint64 soft;
        uint64 hard;
    }

    address public immutable gate;

    mapping(address account => mapping(bytes32 policyId => Caps)) public caps;

    /// @dev Lets a test make the policy refuse to be removed.
    bool public revertOnDeconfigure;

    error CapPolicy_OnlyGate();
    error CapPolicy_Stuck();

    constructor(address gate_) {
        gate = gate_;
    }

    modifier onlyGate() {
        if (msg.sender != gate) revert CapPolicy_OnlyGate();
        _;
    }

    function setRevertOnDeconfigure(bool value) external {
        revertOnDeconfigure = value;
    }

    function classifyConfig(address account, bytes32 policyId, bytes calldata config)
        external
        view
        override
        returns (ConfigChange)
    {
        if (config.length != 64) return ConfigChange.INVALID;
        (uint64 soft, uint64 hard) = abi.decode(config, (uint64, uint64));
        if (soft > hard) return ConfigChange.INVALID;

        Caps memory current = caps[account][policyId];
        if (!current.set) return ConfigChange.TIGHTEN;
        if (soft > current.soft || hard > current.hard) return ConfigChange.WIDEN;
        return ConfigChange.TIGHTEN;
    }

    function configure(address account, bytes32 policyId, bytes calldata config) external override onlyGate {
        (uint64 soft, uint64 hard) = abi.decode(config, (uint64, uint64));
        caps[account][policyId] = Caps({set: true, soft: soft, hard: hard});
    }

    function deconfigure(address account, bytes32 policyId) external override onlyGate {
        if (revertOnDeconfigure) revert CapPolicy_Stuck();
        delete caps[account][policyId];
    }
}

/// @notice A target that forwards whatever it is told to, as a multicall
///         contract would. The spec says such a target is never registered;
///         this shows what happens when one is.
contract RelayTarget {
    bool public lastOk;

    /// @dev Reports the inner failure rather than reverting, so the outer
    ///      transaction survives and the test can inspect the state.
    function forward(address to, bytes calldata data) external {
        (lastOk,) = to.call(data);
    }
}

/// @notice A target that calls back into the gate while the account is calling
///         it.
contract ReentrantTarget {
    PolicyGate public immutable gate;
    bool public reentryOk;
    bytes public reentryError;

    constructor(PolicyGate gate_) {
        gate = gate_;
    }

    function poke(address account, address market, bytes calldata marketCall) external {
        (reentryOk, reentryError) = address(gate).call(abi.encodeCall(gate.submit, (account, market, marketCall)));
    }
}
