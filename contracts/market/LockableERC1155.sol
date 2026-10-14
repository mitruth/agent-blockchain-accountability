// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC1155} from "@openzeppelin/contracts/token/ERC1155/ERC1155.sol";
import {MarketTypes} from "./MarketTypes.sol";
import {EnergyTokenIds} from "./EnergyTokenIds.sol";

/// @title LockableERC1155
/// @notice The market's token: id 0 is the fungible payment token, every other
///         id an energy token. Ported from DEDALUS's `LockableERC1155`, without
///         encryption, on OpenZeppelin's ERC-1155.
///
/// Payment balances can be locked. A prosumer contract locks its owner's
/// collateral when it places an order; the lock names who may release it, and
/// releasing can pay the locked value to a recipient. That is how a buyer pays
/// a seller and how a penalty reaches the manager (thesis, steps 4 and 11).
///
/// What the port changes, and why (decision log, entries from 2.32):
///
///   - Locking is not public. A locker other than the owner uses up the owner's
///     allowance to it, once.
///   - A lock is keyed by owner, locker and unlocker.
///   - No payment token leaves a locked balance by any route: the check is in
///     `_update`, which every transfer, mint and burn goes through.
///   - Only the issuer mints payment tokens. Only minters the market manager
///     appointed mint energy tokens, and never id 0.
///   - The block-count timelock of the original is dropped: both source
///     projects always passed zero.
contract LockableERC1155 is ERC1155 {
    uint256 public constant PAYMENT = 0;

    string public name;

    /// @notice Mints the payment token and appoints the registrar.
    address public immutable issuer;

    /// @notice The market manager. Appoints and withdraws energy minters.
    address public registrar;

    mapping(address minter => bool) public isMinter;

    /// @notice Energy tokens minted so far; the counter in every energy id.
    uint256 public energyTokenCount;

    /// @notice How much of `owner`'s payment balance `operator` may lock.
    mapping(address owner => mapping(address operator => uint256)) public paymentAllowance;

    /// @notice Locked payment value, by owner, locker and unlocker.
    mapping(address owner => mapping(address locker => mapping(address unlocker => uint256))) public lockedBy;

    /// @notice Total locked payment value of `owner`.
    mapping(address owner => uint256) public lockedBalanceOf;

    event RegistrarSet(address indexed registrar);
    event MinterSet(address indexed minter, bool allowed);
    event PaymentAllowance(address indexed owner, address indexed operator, uint256 amount);
    event Locked(address indexed owner, address indexed locker, address indexed unlocker, uint256 value);
    event Unlocked(
        address indexed owner, address indexed locker, address indexed unlocker, uint256 value, address recipient
    );
    event EnergyMinted(
        address indexed minter,
        address indexed to,
        uint256 indexed id,
        uint40 slotStart,
        MarketTypes.EnergyType energyType,
        uint256 quantity
    );

    error LockableERC1155_OnlyIssuer(address caller);
    error LockableERC1155_OnlyRegistrar(address caller);
    error LockableERC1155_RegistrarAlreadySet();
    error LockableERC1155_NotMinter(address caller);
    error LockableERC1155_ZeroQuantity();
    error LockableERC1155_InsufficientAllowance(address owner, address operator, uint256 allowed, uint256 needed);
    error LockableERC1155_InsufficientUnlocked(address owner, uint256 unlocked, uint256 needed);
    error LockableERC1155_InsufficientLock(address owner, address locker, address unlocker, uint256 locked, uint256 needed);
    error LockableERC1155_NotEnergy(uint256 id);
    error LockableERC1155_NotApproved(address caller, address from);
    error LockableERC1155_LockedBalanceMoved(address from, uint256 balance, uint256 locked);

    constructor(string memory name_, string memory uri_) ERC1155(uri_) {
        name = name_;
        issuer = msg.sender;
    }

    // ------------------------------------------------------------------
    // Roles
    // ------------------------------------------------------------------

    /// @notice Name the market manager, once.
    function setRegistrar(address registrar_) external {
        if (msg.sender != issuer) revert LockableERC1155_OnlyIssuer(msg.sender);
        if (registrar != address(0)) revert LockableERC1155_RegistrarAlreadySet();
        registrar = registrar_;
        emit RegistrarSet(registrar_);
    }

    /// @notice Appoint or withdraw an energy minter: a registered prosumer
    ///         contract.
    function setMinter(address minter, bool allowed) external {
        if (msg.sender != registrar) revert LockableERC1155_OnlyRegistrar(msg.sender);
        isMinter[minter] = allowed;
        emit MinterSet(minter, allowed);
    }

    // ------------------------------------------------------------------
    // Minting and burning
    // ------------------------------------------------------------------

    /// @notice Issue payment tokens: the settlement currency of the market.
    function mintPayment(address to, uint256 amount) external {
        if (msg.sender != issuer) revert LockableERC1155_OnlyIssuer(msg.sender);
        _mint(to, PAYMENT, amount, "");
    }

    /// @notice Mint the energy token of one offer: `quantity` Wh for the slot
    ///         starting at `slotStart`.
    function mintEnergy(address to, uint40 slotStart, MarketTypes.EnergyType energyType, uint256 quantity)
        external
        returns (uint256 id)
    {
        if (!isMinter[msg.sender]) revert LockableERC1155_NotMinter(msg.sender);
        if (quantity == 0) revert LockableERC1155_ZeroQuantity();

        id = EnergyTokenIds.encode(msg.sender, slotStart, energyType, ++energyTokenCount);
        _mint(to, id, quantity, "");
        emit EnergyMinted(msg.sender, to, id, slotStart, energyType, quantity);
    }

    /// @notice Burn energy tokens: by their holder, or by an operator the
    ///         holder approved for all. Payment tokens cannot be burned.
    function burnEnergy(address from, uint256 id, uint256 quantity) external {
        if (!EnergyTokenIds.isEnergy(id)) revert LockableERC1155_NotEnergy(id);
        if (from != msg.sender && !isApprovedForAll(from, msg.sender)) {
            revert LockableERC1155_NotApproved(msg.sender, from);
        }
        _burn(from, id, quantity);
    }

    // ------------------------------------------------------------------
    // Locking
    // ------------------------------------------------------------------

    /// @notice Let `operator` lock up to `amount` of the caller's payment
    ///         balance. Each lock uses up as much.
    function setPaymentAllowance(address operator, uint256 amount) external {
        paymentAllowance[msg.sender][operator] = amount;
        emit PaymentAllowance(msg.sender, operator, amount);
    }

    /// @notice Lock `value` of `owner`'s payment balance, releasable by
    ///         `unlocker`. The caller is the locker.
    function lock(address owner, uint256 value, address unlocker) external {
        address locker = msg.sender;
        if (locker != owner) {
            uint256 allowed = paymentAllowance[owner][locker];
            if (allowed < value) revert LockableERC1155_InsufficientAllowance(owner, locker, allowed, value);
            paymentAllowance[owner][locker] = allowed - value;
        }
        uint256 unlocked = unlockedBalanceOf(owner);
        if (unlocked < value) revert LockableERC1155_InsufficientUnlocked(owner, unlocked, value);

        lockedBy[owner][locker][unlocker] += value;
        lockedBalanceOf[owner] += value;
        emit Locked(owner, locker, unlocker, value);
    }

    /// @notice Release `value` of a lock the caller is the unlocker of. With a
    ///         recipient, the released value is paid to it; without, it returns
    ///         to the owner's unlocked balance.
    function unlock(address owner, address locker, uint256 value, address recipient) external {
        _release(owner, locker, msg.sender, value);
        if (recipient != address(0)) _safeTransferFrom(owner, recipient, PAYMENT, value, "");
        emit Unlocked(owner, locker, msg.sender, value, recipient);
    }

    /// @notice Release everything left in a lock the caller is the unlocker of.
    function unlockAll(address owner, address locker) external returns (uint256 value) {
        value = lockedBy[owner][locker][msg.sender];
        _release(owner, locker, msg.sender, value);
        emit Unlocked(owner, locker, msg.sender, value, address(0));
    }

    function unlockedBalanceOf(address owner) public view returns (uint256) {
        return balanceOf(owner, PAYMENT) - lockedBalanceOf[owner];
    }

    // ------------------------------------------------------------------
    // Internals
    // ------------------------------------------------------------------

    function _release(address owner, address locker, address unlocker, uint256 value) private {
        uint256 locked = lockedBy[owner][locker][unlocker];
        if (locked < value) revert LockableERC1155_InsufficientLock(owner, locker, unlocker, locked, value);
        lockedBy[owner][locker][unlocker] = locked - value;
        lockedBalanceOf[owner] -= value;
    }

    /// @dev Every transfer, mint and burn passes here. After it, no sender may
    ///      hold less payment token than it has locked.
    function _update(address from, address to, uint256[] memory ids, uint256[] memory values)
        internal
        override
    {
        super._update(from, to, ids, values);
        if (from == address(0)) return;
        for (uint256 i = 0; i < ids.length; ++i) {
            if (ids[i] == PAYMENT) {
                uint256 balance = balanceOf(from, PAYMENT);
                if (balance < lockedBalanceOf[from]) {
                    revert LockableERC1155_LockedBalanceMoved(from, balance, lockedBalanceOf[from]);
                }
                return;
            }
        }
    }
}
