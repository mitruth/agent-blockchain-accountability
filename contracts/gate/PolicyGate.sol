// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import {IERC7579Module, IERC7579Execution} from "../interfaces/IERC7579.sol";
import {IOrderDecoder} from "../interfaces/IOrderDecoder.sol";
import {DecoderRegistry} from "./DecoderRegistry.sol";
import {ConfigManager} from "./ConfigManager.sol";
import {PositionLedger} from "./PositionLedger.sol";
import {IPolicy} from "../interfaces/IPolicy.sol";
import {Order, OrderKind, Verdict, CheckContext, CheckResult, Release} from "./GateTypes.sol";
import {OracleVerifier} from "../oracle/OracleVerifier.sol";
import {SignedReading} from "../oracle/OracleTypes.sol";

/// @title PolicyGate
/// @notice ERC-7579 executor module through which an autonomous trading agent
///         acts for a prosumer account, and the only way it can.
///
/// The key model (docs/spec/policy-spec-v0.1.md, section 4, as amended by A7).
/// The agent never signs for the account. It holds a Rhinestone Smart Session
/// on the account whose only action is this gate's `submit`, with no signing
/// rights: through it the agent can have the account call `submit`, and
/// nothing else. `submit` therefore takes its caller to be the account. It
/// checks that the call is one the owner approved and -- from step 4.2 -- that
/// every policy passes, and only then has the account make the call.
///
/// Who the agent is, until when, and whether it is revoked, is the session's
/// business: a time-frame policy and `removeSession` on the account. The gate
/// sees the account, so the owner's own `submit` is checked like the agent's.
///
/// What the agent cannot reach, and why:
///
///   the account's module list   its session names `submit` only, and
///                               `submit` never targets the account
///   this gate's registries      its session names `submit` only, and
///                               `submit` never targets the gate
///   the oracle's signer list    `submit` never targets the verifier
///   a policy's configuration    policies accept `configure` from the gate
///                               only, and the gate calls it on the owner path
///
/// Policy checks run here, in execution, and never in `validateUserOp`:
/// ERC-7562 forbids TIMESTAMP and restricts storage reads during validation, so
/// no window and no oracle check could live in a validator.
///
/// Built so far: the key model, the registries, the booking of every order in
/// the position ledger (steps 1 and 2), the session entry point (step 4.1),
/// the policy check, commit and credit phases (step 4.2), and signed readings
/// handed in with an order (step 5.1).
contract PolicyGate is IERC7579Module, DecoderRegistry, ConfigManager {
    uint256 private constant MODULE_TYPE_EXECUTOR = 2;

    /// @dev ERC-7579 mode: one call, revert on failure. Never a batch and never
    ///      a delegatecall.
    bytes32 private constant MODE_SINGLE_CALL = bytes32(0);

    /// @notice Where every order is booked. The account must authorise this
    ///         gate as a writer there, or every submission reverts.
    PositionLedger public immutable ledger;

    /// @notice Where signed readings are verified and kept. The policies read
    ///         the latest from it.
    OracleVerifier public immutable oracle;

    /// @notice Most readings one submission may bring: one per kind, twice
    ///         over.
    uint256 public constant MAX_READINGS = 4;

    /// @notice Most legs one call may decode to: a batch of this many orders,
    ///         or a modification's two. Bounds the booking loop.
    uint256 public immutable maxLegs;

    /// @notice Orders submitted for an account, over all installations. Makes
    ///         every order hash distinct.
    mapping(address account => uint256) public submissionCount;

    /// @notice A submitted call, as decoded: one leg per order placed, one for
    ///         a cancellation, two for a modification. `orderHash` binds the
    ///         chain, this gate, the account, the submission number and the
    ///         exact call.
    event OrderSubmitted(
        address indexed account, address indexed target, bytes4 indexed selector, Order[] legs, bytes32 orderHash
    );

    /// @notice The account made the call.
    event Executed(address indexed account, bytes32 indexed orderHash);

    /// @notice One policy instance's result on a submission, emitted for every
    ///         instance, whatever the outcome (spec 8).
    event PolicyResult(
        address indexed account,
        bytes32 indexed orderHash,
        address indexed policy,
        bytes32 policyId,
        CheckResult result
    );

    /// @notice An instance's soft bound is crossed; the submission goes ahead
    ///         (spec 5.5, flag mode EMIT).
    event PolicyFlag(
        address indexed account,
        bytes32 indexed orderHash,
        address indexed policy,
        bytes32 policyId,
        uint256 valueAfter,
        uint256 soft
    );

    /// @notice At least one instance rejected the submission. Nothing was
    ///         committed, booked or sent to the market. Not a revert: the
    ///         refusal stays in the log.
    event Rejected(address indexed account, bytes32 indexed orderHash);

    /// @notice A policy's credit for released volume failed. The policy keeps
    ///         the charge, which errs on the safe side; the release itself
    ///         stands.
    event CreditFailed(
        address indexed account, address indexed policy, bytes32 policyId, address market, bytes32 orderId
    );

    /// @notice One order brought up to date with the market (spec 5.2). When
    ///         volume is released, the policies are credited.
    event Reconciled(
        address indexed account, address indexed market, bytes32 indexed orderId, uint64 filledWh, uint64 releasedWh
    );

    error PolicyGate_CallDataTooShort();
    error PolicyGate_ForbiddenTarget(address target);
    error PolicyGate_UnknownCall(address target, bytes4 selector);
    error PolicyGate_NotAnOrder(address target, bytes4 selector);
    error PolicyGate_NoReturnData();
    error PolicyGate_PlacedIdsMismatch(uint256 placeLegs, uint256 ids);
    error PolicyGate_MaxLegsTooSmall(uint256 maxLegs);
    error PolicyGate_TooManyReadings(uint256 readings);
    error PolicyGate_ReadingForAnotherAccount(address account);

    /// @param maxLegs_ At least 2, so that a modification fits.
    constructor(PositionLedger ledger_, OracleVerifier oracle_, uint256 maxLegs_) {
        if (maxLegs_ < 2) revert PolicyGate_MaxLegsTooSmall(maxLegs_);
        ledger = ledger_;
        oracle = oracle_;
        maxLegs = maxLegs_;
    }

    // ------------------------------------------------------------------
    // ERC-7579 module
    // ------------------------------------------------------------------

    /// @inheritdoc IERC7579Module
    /// @dev The caller is the account. Nothing is configured here: decoders
    ///      and policies are separate owner-path calls, and the agent's session
    ///      is the account's own, so installing the gate grants nothing.
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

    /// @notice Have the calling account call `target` with `callData`.
    ///
    /// The caller is the account: the agent reaches this through its session,
    /// which allows nothing else. Reverts when the caller is not an account
    /// with the gate installed, when the target is the account, the gate or
    /// the ledger, when the owner has not approved this function of this
    /// target, when the call decodes to no leg or to more than `maxLegs`, when
    /// the market call reverts, and when the ledger refuses a leg: an order it
    /// does not hold, or an open order beyond its bound.
    ///
    /// The readings come next (spec 4.1, step 3): each must be a reading the
    /// oracle verifier accepts for this account -- signed by the account's
    /// device, fresh, and not older than the last from that device -- or the
    /// submission reverts. The policies then read the latest from the verifier.
    ///
    /// Every policy instance of the account checks the submission first, all
    /// legs at once. If any rejects, the submission stops there: `Rejected`
    /// and every instance's `PolicyResult` are emitted, nothing is committed,
    /// booked or sent, and the call returns normally. Otherwise every instance
    /// commits, the account makes the call, and the ledger books the legs.
    ///
    /// Every leg is booked in the ledger after the market call, in order: a
    /// cancellation releases before a placement adds, so a modification at the
    /// open-order bound goes through. Released volume is credited back to the
    /// policies.
    ///
    /// No value is ever sent: the account's native balance is not the agent's
    /// to move.
    ///
    /// @param target   The market contract.
    /// @param callData The call, selector included.
    /// @param readings Signed readings to hand in first, at most MAX_READINGS.
    ///                 May be empty.
    /// @return orderHash Identifier of this submission.
    function submit(address target, bytes calldata callData, SignedReading[] calldata readings)
        external
        onlyAccount
        nonReentrant
        returns (bytes32 orderHash)
    {
        address account = msg.sender;
        (IOrderDecoder decoder, Order[] memory legs) = _decode(account, target, callData);

        orderHash = keccak256(
            abi.encode(block.chainid, address(this), account, submissionCount[account]++, target, keccak256(callData))
        );
        emit OrderSubmitted(account, target, bytes4(callData[:4]), legs, orderHash);

        _acceptReadings(account, readings);

        if (!_checkAndCommit(account, orderHash, target, decoder, legs)) {
            emit Rejected(account, orderHash);
            return orderHash;
        }

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
        if (releasedWh != 0) _creditAll(account, market, orderId, releasedWh);
    }

    // ------------------------------------------------------------------
    // Internals
    // ------------------------------------------------------------------

    /// @dev The ledger trusts "the caller is the account" for its writer list,
    ///      and the oracle verifier for its signer list, so both are forbidden
    ///      targets for the same reason the account and the gate are.
    function _isForbiddenTarget(address account, address target) internal view override returns (bool) {
        return super._isForbiddenTarget(account, target) || target == address(ledger) || target == address(oracle);
    }

    /// @dev The grid lives in the ledger, beside the positions numbered on it.
    ///      The account must have authorised this gate as a writer there.
    function _fixGrid(address account, uint64 origin, uint32 slotSeconds) internal override {
        ledger.fixGrid(account, origin, slotSeconds);
    }

    /// @dev The approved decoder for the call, and the legs it reads.
    function _decode(address account, address target, bytes calldata callData)
        private
        view
        returns (IOrderDecoder decoder, Order[] memory legs)
    {
        if (callData.length < 4) revert PolicyGate_CallDataTooShort();

        // Independent of the registry: even a decoder entry that should never
        // have existed cannot turn the account or the gate into a target.
        if (_isForbiddenTarget(account, target)) revert PolicyGate_ForbiddenTarget(target);

        bytes4 selector = bytes4(callData[:4]);
        decoder = decoderOf(account, target, selector);
        if (address(decoder) == address(0)) revert PolicyGate_UnknownCall(target, selector);

        legs = decoder.decode(target, callData);
        if (legs.length == 0 || legs.length > maxLegs) revert PolicyGate_NotAnOrder(target, selector);
    }

    /// @dev Check phase, then commit phase (spec 4.1, steps 4 to 6). Commits
    ///      only when no instance rejects.
    function _checkAndCommit(
        address account,
        bytes32 orderHash,
        address target,
        IOrderDecoder decoder,
        Order[] memory legs
    ) private returns (bool accepted) {
        CheckContext memory ctx = CheckContext({
            market: target,
            decoder: address(decoder),
            time: uint64(block.timestamp),
            oracle: address(oracle)
        });
        (IPolicy[] memory policies, bytes32[] memory policyIds) = _policyList(account);
        if (!_checkAll(account, orderHash, policies, policyIds, legs, ctx)) return false;
        for (uint256 i = 0; i < policies.length; ++i) {
            policies[i].commit(account, policyIds[i], legs, ctx);
        }
        return true;
    }

    /// @dev Every reading must be for the submitting account. A reading the
    ///      verifier refuses reverts the submission.
    function _acceptReadings(address account, SignedReading[] calldata readings) private {
        if (readings.length > MAX_READINGS) revert PolicyGate_TooManyReadings(readings.length);
        for (uint256 i = 0; i < readings.length; ++i) {
            address forAccount = oracle.accept(readings[i]);
            if (forAccount != account) revert PolicyGate_ReadingForAnotherAccount(forAccount);
        }
    }

    function _book(
        address account,
        address market,
        IOrderDecoder decoder,
        bytes calldata callData,
        Order[] memory legs,
        bytes[] memory results
    ) private {
        uint256 placeLegs;
        for (uint256 i = 0; i < legs.length; ++i) {
            if (legs[i].kind == OrderKind.PLACE) ++placeLegs;
            else if (legs[i].kind != OrderKind.CANCEL) revert PolicyGate_NotAnOrder(market, bytes4(callData[:4]));
        }

        bytes32[] memory placedIds;
        if (placeLegs != 0) {
            if (results.length == 0) revert PolicyGate_NoReturnData();
            placedIds = decoder.placedOrderIds(market, callData, results[0]);
            if (placedIds.length != placeLegs) revert PolicyGate_PlacedIdsMismatch(placeLegs, placedIds.length);
        }

        uint256 nextPlaced;
        for (uint256 i = 0; i < legs.length; ++i) {
            if (legs[i].kind == OrderKind.CANCEL) {
                uint64 releasedWh = ledger.recordCancel(account, market, legs[i].orderId);
                if (releasedWh != 0) _creditAll(account, market, legs[i].orderId, releasedWh);
            } else {
                ledger.recordPlace(account, market, decoder, placedIds[nextPlaced++], legs[i]);
            }
        }
    }

    function _policyList(address account) private view returns (IPolicy[] memory policies, bytes32[] memory ids) {
        PolicyRef[] memory list = policiesOf(account);
        policies = new IPolicy[](list.length);
        ids = new bytes32[](list.length);
        for (uint256 i = 0; i < list.length; ++i) {
            policies[i] = list[i].policy;
            ids[i] = list[i].policyId;
        }
    }

    /// @dev Every instance is asked and every result emitted, even after a
    ///      rejection, so the log holds the whole picture.
    function _checkAll(
        address account,
        bytes32 orderHash,
        IPolicy[] memory policies,
        bytes32[] memory policyIds,
        Order[] memory legs,
        CheckContext memory ctx
    ) private returns (bool accepted) {
        accepted = true;
        for (uint256 i = 0; i < policies.length; ++i) {
            CheckResult memory r = policies[i].check(account, policyIds[i], legs, ctx);
            emit PolicyResult(account, orderHash, address(policies[i]), policyIds[i], r);
            if (r.verdict == Verdict.REJECT) {
                accepted = false;
            } else if (r.verdict == Verdict.FLAG) {
                emit PolicyFlag(account, orderHash, address(policies[i]), policyIds[i], r.valueAfter, r.soft);
            }
        }
    }

    /// @dev Credit every instance for an order's released volume, read from
    ///      the ledger's record. A failing credit is recorded and skipped: the
    ///      charge stays, and a broken policy cannot block reconciliation.
    function _creditAll(address account, address market, bytes32 orderId, uint64 releasedWh) private {
        PositionLedger.OrderRecord memory record = ledger.recordOf(account, market, orderId);
        Release memory release = Release({
            market: market,
            orderId: orderId,
            side: record.side,
            slot: record.slot,
            placedAt: record.placedAt,
            qtyWh: record.qtyWh,
            price: record.price,
            filledWh: record.filledWh,
            releasedWh: releasedWh
        });
        PolicyRef[] memory list = policiesOf(account);
        for (uint256 i = 0; i < list.length; ++i) {
            try list[i].policy.credit(account, list[i].policyId, release) {}
            catch {
                emit CreditFailed(account, address(list[i].policy), list[i].policyId, market, orderId);
            }
        }
    }
}
