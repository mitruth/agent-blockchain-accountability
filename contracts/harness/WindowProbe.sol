// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import {WindowLib} from "../policies/WindowLib.sol";

/// @title WindowProbe
/// @notice WindowLib on its own, for the tests and the independent verifier.
///         Not part of the system.
///
/// It holds any number of windows by id and acts as the smallest possible
/// policy: an amount is admitted if it fits, and consumed if admitted. Every
/// call emits an event carrying the block time, so the whole history of a
/// window can be rebuilt from the event log alone (spec 8) and recomputed by
/// the off-chain verifier.
///
/// Credits refer to an earlier admission, as a real policy's would refer to an
/// order: each admission can be credited once, by at most its amount.
contract WindowProbe {
    using WindowLib for WindowLib.Window;

    struct Admission {
        uint64 amount;
        uint40 at;
        bool credited;
    }

    mapping(uint256 id => WindowLib.Window) private _windows;
    mapping(uint256 id => Admission[]) private _admissions;

    event Configured(uint256 indexed id, uint256 at, WindowLib.Config config);
    event Admitted(uint256 indexed id, uint256 indexed admission, uint256 at, uint64 amount, uint64 usedBefore, uint64 limit);
    event Refused(uint256 indexed id, uint256 at, uint64 amount, uint64 usedBefore, uint64 limit);
    event Credited(uint256 indexed id, uint256 indexed admission, uint256 at, uint64 amount, uint64 credited);
    event Observed(uint256 indexed id, uint256 at, uint64 used, uint64 limit);

    error WindowProbe_NoSuchAdmission(uint256 id, uint256 admission);
    error WindowProbe_AlreadyCredited(uint256 id, uint256 admission);
    error WindowProbe_MoreThanAdmitted(uint256 id, uint256 admission, uint64 amount);

    function configure(uint256 id, WindowLib.Config calldata c) external {
        _windows[id].configure(c);
        emit Configured(id, block.timestamp, c);
    }

    /// @notice Admit `amount` if it fits, and consume it. Refusal does not revert.
    function tryAdd(uint256 id, uint64 amount) external returns (bool admitted) {
        WindowLib.Window storage w = _windows[id];
        uint64 usedBefore = w.used(block.timestamp);
        uint64 lim = w.limit(block.timestamp);
        admitted = w.fits(block.timestamp, amount);
        if (!admitted) {
            emit Refused(id, block.timestamp, amount, usedBefore, lim);
            return false;
        }
        w.add(block.timestamp, amount);
        _admissions[id].push(Admission({amount: amount, at: uint40(block.timestamp), credited: false}));
        emit Admitted(id, _admissions[id].length - 1, block.timestamp, amount, usedBefore, lim);
    }

    /// @notice Give back `amount` of an earlier admission, as a cancelled or
    ///         expired order would.
    function credit(uint256 id, uint256 admission, uint64 amount) external returns (uint64 credited) {
        if (admission >= _admissions[id].length) revert WindowProbe_NoSuchAdmission(id, admission);
        Admission storage a = _admissions[id][admission];
        if (a.credited) revert WindowProbe_AlreadyCredited(id, admission);
        if (amount > a.amount) revert WindowProbe_MoreThanAdmitted(id, admission, amount);
        a.credited = true;
        credited = _windows[id].credit(block.timestamp, a.at, amount);
        emit Credited(id, admission, block.timestamp, amount, credited);
    }

    /// @notice Record what the window counts now.
    function observe(uint256 id) external returns (uint64 used_, uint64 limit_) {
        WindowLib.Window storage w = _windows[id];
        used_ = w.used(block.timestamp);
        limit_ = w.limit(block.timestamp);
        emit Observed(id, block.timestamp, used_, limit_);
    }

    // --- direct access, for unit tests: no admission check, no bookkeeping ---

    function addUnchecked(uint256 id, uint64 amount) external {
        _windows[id].add(block.timestamp, amount);
    }

    function creditAt(uint256 id, uint256 placedAt, uint64 amount) external returns (uint64) {
        return _windows[id].credit(block.timestamp, placedAt, amount);
    }

    function clear(uint256 id) external {
        _windows[id].clear();
    }

    // --- views ---------------------------------------------------------------

    function used(uint256 id) external view returns (uint64) {
        return _windows[id].used(block.timestamp);
    }

    function limit(uint256 id) external view returns (uint64) {
        return _windows[id].limit(block.timestamp);
    }

    function fits(uint256 id, uint64 amount) external view returns (bool) {
        return _windows[id].fits(block.timestamp, amount);
    }

    /// @notice A sliding window's total recomputed from its buckets one by one,
    ///         for the invariant "the total is the sum of the buckets in the
    ///         window".
    function bucketSum(uint256 id) external view returns (uint256) {
        return _windows[id].bucketSum(block.timestamp);
    }

    function stored(uint256 id) external view returns (uint64 used_, uint64 mark, uint64 generation) {
        WindowLib.Window storage w = _windows[id];
        return (w.count, w.mark, w.generation);
    }

    function admissionCount(uint256 id) external view returns (uint256) {
        return _admissions[id].length;
    }

    function admissionOf(uint256 id, uint256 index) external view returns (Admission memory) {
        return _admissions[id][index];
    }

    function configOf(uint256 id) external view returns (WindowLib.Config memory) {
        return _windows[id].config;
    }
}
