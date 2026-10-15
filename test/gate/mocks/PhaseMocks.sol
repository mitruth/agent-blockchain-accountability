// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import {IPolicy} from "../../../contracts/interfaces/IPolicy.sol";
import {PolicyGate} from "../../../contracts/gate/PolicyGate.sol";
import {
    Order, OrderKind, ConfigChange, Verdict, CheckContext, CheckResult, Release
} from "../../../contracts/gate/GateTypes.sol";

/// @notice A test double for the gate's check, commit and credit phases: it
///         counts the Wh placed against a soft and a hard bound, takes back
///         released Wh, and can be made to fail at any phase. Not a policy of
///         the system; the real ones are in contracts/policies/.
contract QtyPolicy is IPolicy {
    struct Bounds {
        bool set;
        uint64 soft;
        uint64 hard;
    }

    address public immutable gate;

    mapping(address account => mapping(bytes32 policyId => Bounds)) public bounds;
    mapping(address account => mapping(bytes32 policyId => uint256)) public placedWh;
    mapping(address account => mapping(bytes32 policyId => uint256)) public commits;

    /// @dev The last release credited, for the tests to inspect.
    Release internal _lastRelease;

    bool public revertOnCheck;
    bool public revertOnCommit;
    bool public revertOnCredit;

    error QtyPolicy_OnlyGate();
    error QtyPolicy_Broken();

    constructor(address gate_) {
        gate = gate_;
    }

    modifier onlyGate() {
        if (msg.sender != gate) revert QtyPolicy_OnlyGate();
        _;
    }

    function breakAt(bool check_, bool commit_, bool credit_) external {
        revertOnCheck = check_;
        revertOnCommit = commit_;
        revertOnCredit = credit_;
    }

    function lastRelease() external view returns (Release memory) {
        return _lastRelease;
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
        Bounds memory current = bounds[account][policyId];
        if (!current.set) return ConfigChange.TIGHTEN;
        return soft > current.soft || hard > current.hard ? ConfigChange.WIDEN : ConfigChange.TIGHTEN;
    }

    function configure(address account, bytes32 policyId, bytes calldata config) external override onlyGate {
        (uint64 soft, uint64 hard) = abi.decode(config, (uint64, uint64));
        bounds[account][policyId] = Bounds({set: true, soft: soft, hard: hard});
    }

    function deconfigure(address account, bytes32 policyId) external override onlyGate {
        delete bounds[account][policyId];
    }

    /// @dev Every PLACE leg counts; a call of cancellations only is never
    ///      rejected (spec D10).
    function check(address account, bytes32 policyId, Order[] calldata legs, CheckContext calldata)
        external
        view
        override
        returns (CheckResult memory r)
    {
        if (revertOnCheck) revert QtyPolicy_Broken();
        Bounds memory b = bounds[account][policyId];
        uint256 adding = _placed(legs);
        r.valueBefore = placedWh[account][policyId];
        r.valueAfter = r.valueBefore + adding;
        r.soft = b.soft;
        r.hard = b.hard;
        if (adding == 0 || r.valueAfter <= b.soft) r.verdict = Verdict.EXECUTE;
        else if (r.valueAfter <= b.hard) r.verdict = Verdict.FLAG;
        else r.verdict = Verdict.REJECT;
    }

    function commit(address account, bytes32 policyId, Order[] calldata legs, CheckContext calldata)
        external
        override
        onlyGate
    {
        if (revertOnCommit) revert QtyPolicy_Broken();
        placedWh[account][policyId] += _placed(legs);
        commits[account][policyId] += 1;
    }

    function credit(address account, bytes32 policyId, Release calldata release) external override onlyGate {
        if (revertOnCredit) revert QtyPolicy_Broken();
        uint256 placed = placedWh[account][policyId];
        placedWh[account][policyId] = release.releasedWh < placed ? placed - release.releasedWh : 0;
        _lastRelease = release;
    }

    function _placed(Order[] calldata legs) private pure returns (uint256 sum) {
        for (uint256 i = 0; i < legs.length; ++i) {
            if (legs[i].kind == OrderKind.PLACE) sum += legs[i].qtyWh;
        }
    }
}

/// @notice A policy that tries to reconcile an order while the gate is
///         committing a submission: it would release volume half-way through.
contract ReentrantPolicy is IPolicy {
    PolicyGate public immutable gate;
    address public account;
    address public market;
    bytes32 public orderId;

    constructor(PolicyGate gate_) {
        gate = gate_;
    }

    function aim(address account_, address market_, bytes32 orderId_) external {
        account = account_;
        market = market_;
        orderId = orderId_;
    }

    function classifyConfig(address, bytes32, bytes calldata) external pure override returns (ConfigChange) {
        return ConfigChange.TIGHTEN;
    }

    function configure(address, bytes32, bytes calldata) external override {}

    function deconfigure(address, bytes32) external override {}

    function check(address, bytes32, Order[] calldata, CheckContext calldata)
        external
        pure
        override
        returns (CheckResult memory r)
    {
        r.verdict = Verdict.EXECUTE;
    }

    function commit(address, bytes32, Order[] calldata, CheckContext calldata) external override {
        gate.reconcile(account, market, orderId);
    }

    function credit(address, bytes32, Release calldata) external override {}
}
