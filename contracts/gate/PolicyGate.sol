// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import {IERC7579Module, IERC7579Execution} from "../interfaces/IERC7579.sol";
import {IOrderDecoder} from "../interfaces/IOrderDecoder.sol";
import {AgentRegistry} from "./AgentRegistry.sol";
import {DecoderRegistry} from "./DecoderRegistry.sol";
import {ConfigManager} from "./ConfigManager.sol";
import {PositionLedger} from "./PositionLedger.sol";
import {Order, OrderKind} from "./GateTypes.sol";

/// @title PolicyGate
/// @notice ERC-7579 executor module through which an autonomous trading agent
///         acts for a prosumer account, and the only way it can.
///
/// The key model (docs/spec/policy-spec-v0.1.md, section 4). The agent never
/// signs for the account. The account's validators belong to the owner alone,
/// and the gate is its only executor. An agent is an ordinary caller of
/// `submit`; the gate checks that the owner registered it, that the call is one
/// the owner approved, and -- from step 4 of the build order -- that every
/// policy passes, and only then asks the account to make the call.
///
/// What the agent cannot reach, and why:
///
///   the account's module list   `submit` never targets the account, so no call
///                               arrives there with the account's own authority
///   this gate's registries      every write takes the owner path, and `submit`
///                               never targets the gate
///   a policy's configuration    policies accept `configure` from the gate
///                               only, and the gate calls it on the owner path
///
/// Policy checks run here, in execution, and never in `validateUserOp`:
/// ERC-7562 forbids TIMESTAMP and restricts storage reads during validation, so
/// no window and no oracle check could live in a validator.
///
/// Steps 1 and 2 of the build order: the key model, the registries, and the
/// booking of every order in the position ledger. Readings and the policy check
/// and commit phases arrive in steps 4 and 5.
contract PolicyGate is IERC7579Module, AgentRegistry, DecoderRegistry, ConfigManager {
    uint256 private constant MODULE_TYPE_EXECUTOR = 2;

    /// @dev ERC-7579 mode: one call, revert on failure. Never a batch and never
    ///      a delegatecall.
    bytes32 private constant MODE_SINGLE_CALL = bytes32(0);

    /// @notice Where every order is booked. The account must authorise this
    ///         gate as a writer there, or every submission reverts.
    PositionLedger public immutable ledger;

    /// @notice Orders submitted for an account, over all installations. Makes
    ///         every order hash distinct.
    mapping(address account => uint256) public submissionCount;

    /// @notice An authorised agent's call, as decoded: one leg for a placement
    ///         or a cancellation, two for a modification. `orderHash` binds the
    ///         chain, this gate, the account, the submission number and the
    ///         exact call.
    event OrderSubmitted(
        address indexed account,
        address indexed agent,
        address indexed target,
        bytes4 selector,
        Order[] legs,
        bytes32 orderHash
    );

    /// @notice The account made the call.
    event Executed(address indexed account, bytes32 indexed orderHash);

    /// @notice One order brought up to date with the market (spec 5.2).
    ///         Credits to the policies for released volume arrive in step 4.
    event Reconciled(
        address indexed account, address indexed market, bytes32 indexed orderId, uint64 filledWh, uint64 releasedWh
    );

    error PolicyGate_AgentNotAuthorized(address account, address agent);
    error PolicyGate_CallDataTooShort();
    error PolicyGate_ForbiddenTarget(address target);
    error PolicyGate_UnknownCall(address target, bytes4 selector);
    error PolicyGate_NotAnOrder(address target, bytes4 selector);
    error PolicyGate_NoReturnData();

    constructor(PositionLedger ledger_) {
        ledger = ledger_;
    }

    // ------------------------------------------------------------------
    // ERC-7579 module
    // ------------------------------------------------------------------

    /// @inheritdoc IERC7579Module
    /// @dev The caller is the account. Nothing is configured here: agents,
    ///      decoders and policies are separate owner-path calls, so that
    ///      installing the gate never grants an agent anything by itself.
    function onInstall(bytes calldata) external override nonReentrant {
        _install(msg.sender);
    }

    /// @inheritdoc IERC7579Module
    function onUninstall(bytes calldata) external override nonReentrant {
        _deconfigureAll(msg.sender);
        _uninstall(msg.sender);
    }

    /// @inheritdoc IERC7579Module
    function isModuleType(uint256 moduleTypeId) external pure override returns (bool) {
        return moduleTypeId == MODULE_TYPE_EXECUTOR;
    }

    /// @inheritdoc IERC7579Module
    function isInitialized(address smartAccount) external view override returns (bool) {
        return isInstalled(smartAccount);
    }

    // ------------------------------------------------------------------
    // The agent's one entry point
    // ------------------------------------------------------------------

    /// @notice Ask `account` to call `target` with `callData`.
    ///
    /// Reverts when the caller is not an active agent of the account, when the
    /// target is the account, the gate or the ledger, when the owner has not
    /// approved this function of this target, when the call is not one or two
    /// order legs, when the market call reverts, and when the ledger refuses a
    /// leg: an order it does not hold, or an open order beyond its bound.
    ///
    /// Every leg is booked in the ledger after the market call, in order: a
    /// cancellation releases before a placement adds, so a modification at the
    /// open-order bound goes through.
    ///
    /// No value is ever sent: the account's native balance is not the agent's
    /// to move.
    ///
    /// @param account  The prosumer account to act for.
    /// @param target   The market contract.
    /// @param callData The call, selector included.
    /// @return orderHash Identifier of this submission.
    function submit(address account, address target, bytes calldata callData)
        external
        nonReentrant
        returns (bytes32 orderHash)
    {
        if (!isAgentActive(account, msg.sender)) revert PolicyGate_AgentNotAuthorized(account, msg.sender);
        if (callData.length < 4) revert PolicyGate_CallDataTooShort();

        // Independent of the registry: even a decoder entry that should never
        // have existed cannot turn the account or the gate into a target.
        if (_isForbiddenTarget(account, target)) revert PolicyGate_ForbiddenTarget(target);

        bytes4 selector = bytes4(callData[:4]);
        IOrderDecoder decoder = decoderOf(account, target, selector);
        if (address(decoder) == address(0)) revert PolicyGate_UnknownCall(target, selector);

        Order[] memory legs = decoder.decode(target, callData);
        if (legs.length == 0 || legs.length > 2) revert PolicyGate_NotAnOrder(target, selector);

        orderHash = keccak256(
            abi.encode(block.chainid, address(this), account, submissionCount[account]++, target, keccak256(callData))
        );
        emit OrderSubmitted(account, msg.sender, target, selector, legs, orderHash);

        bytes[] memory results =
            IERC7579Execution(account).executeFromExecutor(MODE_SINGLE_CALL, abi.encodePacked(target, uint256(0), callData));

        _book(account, target, decoder, callData, legs, results);

        emit Executed(account, orderHash);
    }

    /// @notice Bring one order up to date with the market: book new fills,
    ///         and release what is unfilled once the slot's gate has closed.
    ///
    /// Anyone may call it: a keeper, the agent, the owner. Nothing it does
    /// depends on the caller, and every quantity comes from the market through
    /// the order's decoder.
    function reconcile(address account, address market, bytes32 orderId)
        external
        nonReentrant
        returns (uint64 filledWh, uint64 releasedWh)
    {
        (filledWh, releasedWh) = ledger.reconcile(account, market, orderId);
        emit Reconciled(account, market, orderId, filledWh, releasedWh);
    }

    // ------------------------------------------------------------------
    // Internals
    // ------------------------------------------------------------------

    /// @dev The ledger trusts "the caller is the account" for its writer list,
    ///      so it is a forbidden target for the same reason the account and the
    ///      gate are.
    function _isForbiddenTarget(address account, address target) internal view override returns (bool) {
        return super._isForbiddenTarget(account, target) || target == address(ledger);
    }

    function _book(
        address account,
        address market,
        IOrderDecoder decoder,
        bytes calldata callData,
        Order[] memory legs,
        bytes[] memory results
    ) private {
        for (uint256 i = 0; i < legs.length; ++i) {
            if (legs[i].kind == OrderKind.CANCEL) {
                ledger.recordCancel(account, market, legs[i].orderId);
            } else if (legs[i].kind == OrderKind.PLACE) {
                if (results.length == 0) revert PolicyGate_NoReturnData();
                bytes32 orderId = decoder.placedOrderId(market, callData, results[0]);
                ledger.recordPlace(account, market, decoder, orderId, legs[i]);
            } else {
                revert PolicyGate_NotAnOrder(market, bytes4(callData[:4]));
            }
        }
    }
}
