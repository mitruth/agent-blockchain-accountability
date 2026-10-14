// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {PolicyConfig} from "../../contracts/earlier-design/PolicyConfig.sol";
import {SpendLedger} from "../../contracts/earlier-design/SpendLedger.sol";
import {SpendValidator} from "../../contracts/earlier-design/SpendValidator.sol";
import {SmartAccount} from "../../contracts/earlier-design/SmartAccount.sol";
import {PriceOracle} from "../../contracts/earlier-design/PriceOracle.sol";
import {MeterReadings} from "../../contracts/earlier-design/MeterReadings.sol";

/// The on-chain half of the differential.
///
/// Replays real days through the real path -- the oracle publishes prices, the
/// meter signs readings, settleDay computes and records spend -- and writes the
/// chain's verdict to earlier-design/differential/data/chain/. earlier-design/differential/run_diff.py feeds
/// the same readings, prices and captured policy events to the independent
/// verifier and compares the two, day by day.
///
/// Inputs come from earlier-design/differential/build_settlement_inputs.py: per arm, 364 UTC
/// days of 48 half-hours from the HEMS simulator's step log.
///
/// Policy events are captured from the PolicyUpdated log, not read back from
/// storage, so the verifier sees what a third party watching the chain sees.
contract DifferentialTest is Test {
    string internal constant INPUTS = "earlier-design/differential/data/inputs/";
    string internal constant CHAIN = "earlier-design/differential/data/chain/";

    /// Per day in the packed input: uint64 day, 48 x uint32 import,
    /// 48 x uint32 export, 48 x int32 import price, 48 x int32 export price.
    uint256 internal constant DAY_BYTES = 8 + 48 * 4 * 4;

    bytes32 internal constant POLICY_UPDATED_SIG =
        keccak256("PolicyUpdated(uint256,int256,uint32,uint64,uint64,address)");

    address internal owner = makeAddr("owner");
    address internal agent = makeAddr("agentSessionKey");
    address internal guardian = makeAddr("guardian");
    address internal publisher = makeAddr("pricePublisher");
    address internal meter;
    uint256 internal meterKey;

    PolicyConfig internal config;
    SpendLedger internal ledger;
    SpendValidator internal validator;
    SmartAccount internal account;
    PriceOracle internal oracle;

    uint256 internal policySeq;

    struct Day {
        uint64 index;
        uint64[48] imp;
        uint64[48] exp;
        int64[48] pi;
        int64[48] pe;
    }

    function setUp() public {
        (meter, meterKey) = makeAddrAndKey("meter");
    }

    // ------------------------------------------------------------------
    // Scenarios
    // ------------------------------------------------------------------

    function test_diff_B0() public {
        _run("B0", "B0", 100000, 7, 364, false);
    }

    function test_diff_B1() public {
        _run("B1", "B1", 100000, 7, 364, false);
    }

    function test_diff_B2() public {
        _run("B2", "B2", 100000, 7, 364, false);
    }

    /// A tight cap, so a large share of days breach and authority is withdrawn
    /// often. Exercises the far side of every comparison on real data.
    function test_diff_B2_strict() public {
        _run("B2strict", "B2", 18096, 7, 364, false);
    }

    /// The cap equals B2's largest 7-day window sum, 107,036 milli-USD, reached
    /// on day 19349 and nowhere else. One real day sits exactly at the cap, so
    /// the equality rule is exercised on real data. Added after a chain mutation
    /// refusing equality went unnoticed: no other scenario ever lands on it.
    function test_diff_B2_atCap() public {
        _run("B2atCap", "B2", 107036, 7, 364, false);
    }

    /// Real B2 days under a schedule of policy writes aimed at every clause of
    /// spec section 7. See _churn.
    function test_diff_churn() public {
        _run("churn", "B2", 14000, 7, 60, true);
    }

    // ------------------------------------------------------------------
    // Driver
    // ------------------------------------------------------------------

    function _run(
        string memory label,
        string memory arm,
        int256 cap,
        uint32 windowDays,
        uint256 maxDays,
        bool churn
    ) internal {
        bytes memory blob = vm.parseBytes(vm.readFile(string.concat(INPUTS, arm, ".days.hex")));
        require(blob.length % DAY_BYTES == 0, "Differential: malformed input blob");
        uint256 dayCount = blob.length / DAY_BYTES;
        if (dayCount > maxDays) dayCount = maxDays;

        uint64 firstDay = _readDay(blob, 0).index;
        uint64 lastDay = firstDay + uint64(dayCount) - 1;

        string memory daysPath = string.concat(CHAIN, label, ".days.csv");
        string memory policyPath = string.concat(CHAIN, label, ".policy.csv");
        vm.writeFile(daysPath, "dayIndex,spendMilliUsd,windowSum,capInForce,windowDaysInForce,policyVersion,compliant,authorisedNextDay\n");
        vm.writeFile(policyPath, "seq,policyVersion,cap,windowDays,submittedOnDay,effectiveFromDay,setBy\n");
        vm.writeFile(
            string.concat(CHAIN, label, ".meta.csv"),
            string.concat("scenario,arm,firstDay,lastDay\n", label, ",", arm, ",",
                vm.toString(uint256(firstDay)), ",", vm.toString(uint256(lastDay)), "\n")
        );

        _warpToDay(firstDay);
        policySeq = 0;
        vm.recordLogs();
        _deploy(firstDay, cap, windowDays);
        _drainPolicyEvents(policyPath);

        for (uint256 k = 0; k < dayCount; k++) {
            Day memory d = _readDay(blob, k);
            require(d.index == firstDay + uint64(k), "Differential: input days not consecutive");

            // Stand on the following day: the day being settled has ended.
            _warpToDay(d.index + 1);
            if (churn) {
                _churn(d.index + 1 - firstDay, policyPath);
            }

            bool compliant = _settle(d);
            _writeDay(daysPath, d.index, compliant);
        }
    }

    function _deploy(uint64 genesisDay, int256 cap, uint32 windowDays) internal {
        vm.prank(publisher);
        oracle = new PriceOracle(publisher);

        vm.startPrank(owner);
        config = new PolicyConfig(guardian, agent, cap, windowDays, 72 hours, 6 hours);
        ledger = new SpendLedger();
        account = new SmartAccount(config, ledger);
        validator = new SpendValidator(config, ledger, address(account), genesisDay);
        account.installModule(address(validator));
        account.setSpendValidator(address(validator));
        ledger.setWriter(address(validator), true);
        config.setPriceOracle(address(oracle));
        config.setMeter(meter);
        vm.stopPrank();
    }

    /// Returns the contract's own compliance verdict, taken from DaySettled.
    function _settle(Day memory d) internal returns (bool compliant) {
        vm.prank(publisher);
        oracle.publishDay(d.index, d.pi, d.pe);

        bytes32 hash = MeterReadings.digest(block.chainid, address(ledger), d.index, d.imp, d.exp);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(meterKey, hash);

        vm.recordLogs();
        validator.settleDay(
            SpendValidator.DayReadings(d.index, d.imp, d.exp, abi.encodePacked(r, s, v)),
            SpendValidator.DayPrices(d.pi, d.pe)
        );

        Vm.Log[] memory logs = vm.getRecordedLogs();
        bool found;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics.length == 0 || logs[i].topics[0] != SpendValidator.DaySettled.selector) continue;
            (,,, compliant,) = abi.decode(logs[i].data, (int256, int256, int256, bool, uint256));
            found = true;
        }
        require(found, "Differential: DaySettled not captured");
    }

    // ------------------------------------------------------------------
    // Policy churn on real days
    //
    // Offsets are submission days counted from the first day. The first day of
    // the B2 input is 18994, and 18994 mod 7 = 3, so under a 7-day window the
    // boundaries fall on offsets 4, 11, 18, 25, ...
    // ------------------------------------------------------------------

    function _churn(uint64 offset, string memory policyPath) internal {
        if (offset == 2) {
            _setPolicy(20000, 7, policyPath); // raise: deferred to boundary, offset 4
        } else if (offset == 3) {
            _setPolicy(30000, 7, policyPath); // second raise, same boundary: later write wins
        } else if (offset == 4) {
            // A lowering submitted ON the boundary the pending raise targets.
            // Not later than today, so not cancelled -- but effective the same
            // day, so the later write wins. Two rules meet here.
            _setPolicy(12000, 7, policyPath);
        } else if (offset == 11) {
            _setPolicy(25000, 7, policyPath); // raise submitted on a boundary: deferred a full window, to 18
        } else if (offset == 13) {
            // An unchanged cap is not a raise, so it applies at once and cancels
            // the raise still pending for offset 18.
            _setPolicy(12000, 7, policyPath);
        } else if (offset == 20) {
            _setPolicy(12000, 3, policyPath); // window length only, immediate
        } else if (offset == 25) {
            // A raise that also lengthens the window. The boundary is measured
            // with the incumbent 3-day window: 19019 -> 19020, offset 26.
            _setPolicy(16000, 7, policyPath);
        } else if (offset == 30) {
            _setPolicy(6000, 7, policyPath); // lowering below the current window sum
        } else if (offset == 40) {
            _setPolicy(40000, 7, policyPath); // raise: 19034 -> boundary 19040, offset 46
        }
    }

    function _setPolicy(int256 cap, uint32 windowDays, string memory policyPath) internal {
        vm.recordLogs();
        vm.prank(owner);
        config.setPolicy(cap, windowDays);
        _drainPolicyEvents(policyPath);
    }

    // ------------------------------------------------------------------
    // Output
    // ------------------------------------------------------------------

    function _drainPolicyEvents(string memory policyPath) internal {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        uint256 captured;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics.length == 0 || logs[i].topics[0] != POLICY_UPDATED_SIG) continue;

            uint256 version = uint256(logs[i].topics[1]);
            (int256 cap, uint32 windowDays, uint64 submitted, uint64 effective, address setBy) =
                abi.decode(logs[i].data, (int256, uint32, uint64, uint64, address));

            string memory head = string.concat(
                vm.toString(policySeq), ",", vm.toString(version), ",", vm.toString(cap), ","
            );
            string memory tail = string.concat(
                vm.toString(uint256(windowDays)), ",", vm.toString(uint256(submitted)), ",",
                vm.toString(uint256(effective)), ",", vm.toString(setBy)
            );
            vm.writeLine(policyPath, string.concat(head, tail));
            policySeq++;
            captured++;
        }
        // A policy write that leaves no PolicyUpdated behind means the
        // signature above no longer matches the contract. Fail loudly rather
        // than hand the verifier an empty policy log.
        require(captured > 0, "Differential: no PolicyUpdated captured; event signature drift?");
    }

    /// One row per settled day. `compliant` is the contract's verdict from
    /// DaySettled, not recomputed here. authorisedNextDay is read immediately
    /// after settling the day, standing on the following day with that day's
    /// policy writes already applied.
    function _writeDay(string memory daysPath, uint64 day, bool compliant) internal {
        SpendLedger.DayRecord memory rec = ledger.recordOf(day);
        int256 sum = validator.windowSum(day);
        int256 cap = config.capAt(day);

        string memory head = string.concat(
            vm.toString(uint256(day)), ",", vm.toString(rec.netSpend), ",", vm.toString(sum), ","
        );
        string memory tail = string.concat(
            vm.toString(cap), ",", vm.toString(uint256(config.windowDaysAt(day))), ",",
            vm.toString(rec.policyVersion), ",", compliant ? "true" : "false", ",",
            validator.isAgentAuthorized() ? "true" : "false"
        );
        vm.writeLine(daysPath, string.concat(head, tail));
    }

    // ------------------------------------------------------------------
    // Input decoding
    // ------------------------------------------------------------------

    function _readDay(bytes memory blob, uint256 k) internal pure returns (Day memory d) {
        uint256 base;
        uint256 word;
        assembly {
            base := add(add(blob, 32), mul(k, 776))
            word := mload(base)
        }
        d.index = uint64(word >> 192);

        for (uint256 i = 0; i < 48; i++) {
            uint256 at = base + 8 + 4 * i;
            assembly { word := mload(at) }
            d.imp[i] = uint64(uint32(word >> 224));

            at = base + 8 + 192 + 4 * i;
            assembly { word := mload(at) }
            d.exp[i] = uint64(uint32(word >> 224));

            at = base + 8 + 384 + 4 * i;
            assembly { word := mload(at) }
            d.pi[i] = int64(int32(uint32(word >> 224)));

            at = base + 8 + 576 + 4 * i;
            assembly { word := mload(at) }
            d.pe[i] = int64(int32(uint32(word >> 224)));
        }
    }

    function _warpToDay(uint64 day) internal {
        vm.warp(uint256(day) * 86400 + 3600);
    }
}
