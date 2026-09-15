// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {PolicyConfig} from "../contracts/PolicyConfig.sol";
import {SpendLedger} from "../contracts/SpendLedger.sol";
import {SpendValidator} from "../contracts/SpendValidator.sol";
import {SmartAccount} from "../contracts/SmartAccount.sol";
import {PriceOracle} from "../contracts/PriceOracle.sol";
import {MeterReadings} from "../contracts/MeterReadings.sol";
import {SpendMath} from "../contracts/SpendMath.sol";

/// Stage A3: daily spend computed on-chain from measured inputs.
///
/// What must hold:
///   - a real simulator day produces the simulator's own energy cost
///   - rounding is half away from zero, once per day, in both signs
///   - only readings signed by the registered meter, for this ledger, and
///     prices exactly as the oracle published them, are accepted
///   - anyone may relay; days settle strictly in the past and strictly in order
///   - an over-cap day is recorded, not refused
contract SettlementTest is Test {
    PolicyConfig internal config;
    SpendLedger internal ledger;
    SpendValidator internal validator;
    SmartAccount internal account;
    PriceOracle internal oracle;

    address internal owner = makeAddr("owner");
    address internal agent;
    uint256 internal agentKey;
    address internal guardian = makeAddr("guardian");
    address internal publisher = makeAddr("pricePublisher");
    address internal meter;
    uint256 internal meterKey;
    address internal stranger = makeAddr("stranger");

    int256 internal constant CAP = 10000; // milli-USD over 7 days
    uint32 internal constant WINDOW_DAYS = 7;

    /// 2022-06-15 UTC. The real day in test_realDayMatchesSimulatorEnergyCost.
    uint64 internal constant GENESIS = 19158;

    function setUp() public {
        (meter, meterKey) = makeAddrAndKey("meter");
        (agent, agentKey) = makeAddrAndKey("agentSessionKey");

        vm.warp(uint256(GENESIS + 30) * 86400);

        vm.prank(publisher);
        oracle = new PriceOracle(publisher);

        vm.startPrank(owner);
        config = new PolicyConfig(guardian, agent, CAP, WINDOW_DAYS, 72 hours, 6 hours);
        ledger = new SpendLedger();
        account = new SmartAccount(config, ledger);
        validator = new SpendValidator(config, ledger, address(account), GENESIS);
        account.installModule(address(validator));
        account.setSpendValidator(address(validator));
        ledger.setWriter(address(validator), true);
        config.setPriceOracle(address(oracle));
        config.setMeter(meter);
        vm.stopPrank();
    }

    // ------------------------------------------------------------------
    // Helpers
    // ------------------------------------------------------------------

    function _publish(uint64 day, int64[48] memory importPrices, int64[48] memory exportPrices) internal {
        vm.prank(publisher);
        oracle.publishDay(day, importPrices, exportPrices);
    }

    function _sign(uint256 key, bytes32 hash) internal pure returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(key, hash);
        return abi.encodePacked(r, s, v);
    }

    function _readings(uint64 day, uint64[48] memory imp, uint64[48] memory exp, uint256 key)
        internal
        view
        returns (SpendValidator.DayReadings memory)
    {
        bytes32 hash = MeterReadings.digest(block.chainid, address(ledger), day, imp, exp);
        return SpendValidator.DayReadings(day, imp, exp, _sign(key, hash));
    }

    /// A flat day: every half-hour imports `importEach` mWh at 0.1 USD/kWh.
    /// 48 × 100,000 mWh × 1e7 = 4.8e13, which is 480 milli-USD.
    function _flatDay(uint64 day, uint64 importEach)
        internal
        returns (SpendValidator.DayReadings memory readings, SpendValidator.DayPrices memory prices)
    {
        uint64[48] memory imp;
        uint64[48] memory exp;
        int64[48] memory pi;
        int64[48] memory pe;
        for (uint256 i = 0; i < 48; i++) {
            imp[i] = importEach;
            pi[i] = 10_000_000;
            pe[i] = 3_000_000;
        }
        _publish(day, pi, pe);
        readings = _readings(day, imp, exp, meterKey);
        prices = SpendValidator.DayPrices(pi, pe);
    }

    function _settleFlat(uint64 day, uint64 importEach) internal {
        (SpendValidator.DayReadings memory r, SpendValidator.DayPrices memory p) = _flatDay(day, importEach);
        validator.settleDay(r, p);
    }

    // ------------------------------------------------------------------
    // The arithmetic agrees with the simulator
    // ------------------------------------------------------------------

    /// UTC day 2022-06-15 from the B2 controller's step log for home_01, mapped
    /// from the dataset's clock as fixed UTC-8 (D7.7), readings rounded to mWh
    /// and prices to 1e-8 USD/kWh the way the simulated meter and publisher do.
    ///
    /// The simulator's own float energy cost for those 48 half-hours is
    /// 26.315984 milli-USD. After quantisation the exact total is
    /// 26.31599227524, and rounded once it is 26. The quantisation shifts the
    /// day by 0.000008 milli-USD.
    ///
    /// A day with both imports and exports, 36 exporting half-hours, and prices
    /// spanning more than 40x -- not a case built to be easy.
    function test_realDayMatchesSimulatorEnergyCost() public {
        uint64[48] memory imp = [uint64(0), 0, 0, 2461367, 2674718, 0, 0, 665794, 289145, 0, 224111, 217581, 201061, 210893, 747204, 1706916, 545947, 0, 0, 0, 14860, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0];
        uint64[48] memory exp = [uint64(1018556), 839057, 662009, 0, 0, 674383, 128931, 0, 0, 276493, 0, 0, 0, 0, 0, 0, 0, 64517, 88776, 9359, 0, 18204, 5359, 6542, 3705, 11913, 20077, 58044, 151688, 326008, 494830, 140004, 957496, 96451, 1161737, 1439031, 58458, 215624, 1700573, 1759491, 1771204, 1761570, 1711788, 1644966, 1566625, 1451680, 1320021, 1169790];
        int64[48] memory pi = [int64(1261160), 3466462, 4151643, 4375941, 4796663, 59522656, 23118909, 14320104, 15531492, 16729072, 10486933, 9247848, 9880222, 8253462, 8036119, 6416151, 4887214, 8205495, 7738343, 7228055, 7837713, 7226150, 6975394, 7025434, 7107755, 9140411, 9435889, 9854274, 11165740, 5669868, 6177116, 3741779, 5962308, 3857939, 5235278, 5313307, 3406404, 4874497, 6460379, 6647427, 7535213, 7660400, 7611626, 8361834, 7615307, 8756251, 9761481, 8817481];
        int64[48] memory pe = [int64(378348), 1039939, 1245493, 1312782, 1438999, 17856797, 6935673, 4296031, 4659448, 5018722, 3146080, 2774354, 2964067, 2476039, 2410836, 1924845, 1466164, 2461649, 2321503, 2168417, 2351314, 2167845, 2092618, 2107630, 2132327, 2742123, 2830767, 2956282, 3349722, 1700960, 1853135, 1122534, 1788692, 1157382, 1570583, 1593992, 1021921, 1462349, 1938114, 1994228, 2260564, 2298120, 2283488, 2508550, 2284592, 2626875, 2928444, 2645244];

        assertEq(SpendMath.dailyNumerator(imp, exp, pi, pe), 2631599227524, "exact total in 1e-14 USD");

        _publish(GENESIS, pi, pe);
        validator.settleDay(_readings(GENESIS, imp, exp, meterKey), SpendValidator.DayPrices(pi, pe));

        assertTrue(ledger.isRecorded(GENESIS));
        assertEq(ledger.netSpendOf(GENESIS), 26, "simulator cost 26.315984 mUSD rounds to 26");
    }

    function test_flatDayIsRecordedWithItsPolicyVersion() public {
        _settleFlat(GENESIS, 100_000);

        SpendLedger.DayRecord memory rec = ledger.recordOf(GENESIS);
        assertEq(rec.netSpend, 480);
        assertEq(rec.policyVersion, 1);
        assertEq(validator.windowSum(GENESIS), 480);
    }

    // ------------------------------------------------------------------
    // Rounding: half away from zero, once per day
    // ------------------------------------------------------------------

    function test_roundingRuleDirectly() public pure {
        assertEq(SpendMath.divRoundHalfAwayFromZero(250, 100), 3, "+2.5 -> +3");
        assertEq(SpendMath.divRoundHalfAwayFromZero(-250, 100), -3, "-2.5 -> -3");
        assertEq(SpendMath.divRoundHalfAwayFromZero(350, 100), 4, "+3.5 -> +4");
        assertEq(SpendMath.divRoundHalfAwayFromZero(-350, 100), -4, "-3.5 -> -4");
        assertEq(SpendMath.divRoundHalfAwayFromZero(249, 100), 2, "+2.49 -> +2");
        assertEq(SpendMath.divRoundHalfAwayFromZero(-249, 100), -2, "-2.49 -> -2");
        assertEq(SpendMath.divRoundHalfAwayFromZero(251, 100), 3, "+2.51 -> +3");
        assertEq(SpendMath.divRoundHalfAwayFromZero(50, 100), 1, "+0.5 -> +1");
        assertEq(SpendMath.divRoundHalfAwayFromZero(-50, 100), -1, "-0.5 -> -1");
        assertEq(SpendMath.divRoundHalfAwayFromZero(49, 100), 0, "+0.49 -> 0");
        assertEq(SpendMath.divRoundHalfAwayFromZero(-49, 100), 0, "-0.49 -> 0");
        assertEq(SpendMath.divRoundHalfAwayFromZero(0, 100), 0);
    }

    function _oneSlotDay(uint64 day, uint64 importMWh, uint64 exportMWh, int64 importPrice, int64 exportPrice)
        internal
        returns (int256)
    {
        uint64[48] memory imp;
        uint64[48] memory exp;
        int64[48] memory pi;
        int64[48] memory pe;
        imp[0] = importMWh;
        exp[0] = exportMWh;
        pi[0] = importPrice;
        pe[0] = exportPrice;
        _publish(day, pi, pe);
        validator.settleDay(_readings(day, imp, exp, meterKey), SpendValidator.DayPrices(pi, pe));
        return ledger.netSpendOf(day);
    }

    /// 15 Wh at 0.1 USD/kWh is exactly 1.5 milli-USD.
    function test_settledHalfRoundsAwayFromZeroPositive() public {
        assertEq(_oneSlotDay(GENESIS, 15_000, 0, 10_000_000, 0), 2);
    }

    /// 15 Wh exported at 0.1 USD/kWh is exactly -1.5 milli-USD.
    function test_settledHalfRoundsAwayFromZeroNegative() public {
        assertEq(_oneSlotDay(GENESIS, 0, 15_000, 0, 10_000_000), -2);
    }

    function test_settledJustBelowHalfRoundsDown() public {
        assertEq(_oneSlotDay(GENESIS, 14_999, 0, 10_000_000, 0), 1);
    }

    /// A negative import price is real on CAISO. Importing then earns money.
    function test_negativeImportPriceReducesSpend() public {
        // 1 kWh at -0.025 USD/kWh = -25 milli-USD
        assertEq(_oneSlotDay(GENESIS, 1_000_000, 0, -2_500_000, 0), -25);
    }

    // ------------------------------------------------------------------
    // Anyone may relay
    // ------------------------------------------------------------------

    /// Authenticity comes from the meter's signature, not from the sender. A
    /// day the agent would rather not report can be settled by anyone.
    function test_anyoneMayRelay() public {
        (SpendValidator.DayReadings memory r0, SpendValidator.DayPrices memory p0) = _flatDay(GENESIS, 100_000);
        (SpendValidator.DayReadings memory r1, SpendValidator.DayPrices memory p1) = _flatDay(GENESIS + 1, 100_000);
        (SpendValidator.DayReadings memory r2, SpendValidator.DayPrices memory p2) = _flatDay(GENESIS + 2, 100_000);

        vm.prank(stranger);
        validator.settleDay(r0, p0);
        vm.prank(guardian);
        validator.settleDay(r1, p1);
        vm.prank(agent);
        validator.settleDay(r2, p2);

        assertEq(validator.windowSum(GENESIS + 2), 1440);
    }

    // ------------------------------------------------------------------
    // Only the meter's readings
    // ------------------------------------------------------------------

    /// The heart of F8. Readings the agent signed itself are refused.
    function test_readingsSignedByTheAgentAreRejected() public {
        (SpendValidator.DayReadings memory r, SpendValidator.DayPrices memory p) = _flatDay(GENESIS, 100_000);
        SpendValidator.DayReadings memory forged = _readings(GENESIS, r.importMWh, r.exportMWh, agentKey);

        vm.expectRevert(abi.encodeWithSelector(SpendValidator.SpendValidator_NotSignedByMeter.selector, agent));
        validator.settleDay(forged, p);
        assertFalse(ledger.isRecorded(GENESIS));
    }

    /// Genuine signature, one reading lowered afterwards.
    function test_tamperedReadingIsRejected() public {
        (SpendValidator.DayReadings memory r, SpendValidator.DayPrices memory p) = _flatDay(GENESIS, 100_000);
        r.importMWh[10] = 0;
        address wrongSigner = MeterReadings.recover(
            MeterReadings.digest(block.chainid, address(ledger), GENESIS, r.importMWh, r.exportMWh),
            r.meterSignature
        );

        vm.expectRevert(abi.encodeWithSelector(SpendValidator.SpendValidator_NotSignedByMeter.selector, wrongSigner));
        validator.settleDay(r, p);
    }

    /// Readings genuinely signed by this meter, but for another household's
    /// ledger, are not valid here.
    function test_readingsSignedForAnotherLedgerAreRejected() public {
        (SpendValidator.DayReadings memory r, SpendValidator.DayPrices memory p) = _flatDay(GENESIS, 100_000);
        bytes32 otherLedgerHash = MeterReadings.digest(block.chainid, address(0xBEEF), GENESIS, r.importMWh, r.exportMWh);
        r.meterSignature = _sign(meterKey, otherLedgerHash);
        address wrongSigner = MeterReadings.recover(
            MeterReadings.digest(block.chainid, address(ledger), GENESIS, r.importMWh, r.exportMWh),
            r.meterSignature
        );

        vm.expectRevert(abi.encodeWithSelector(SpendValidator.SpendValidator_NotSignedByMeter.selector, wrongSigner));
        validator.settleDay(r, p);
    }

    function test_simultaneousImportAndExportIsRejected() public {
        uint64[48] memory imp;
        uint64[48] memory exp;
        int64[48] memory pi;
        int64[48] memory pe;
        imp[5] = 1000;
        exp[5] = 1000;
        _publish(GENESIS, pi, pe);
        SpendValidator.DayReadings memory r = _readings(GENESIS, imp, exp, meterKey);

        vm.expectRevert(abi.encodeWithSelector(SpendValidator.SpendValidator_ImportAndExportOverlap.selector, 5));
        validator.settleDay(r, SpendValidator.DayPrices(pi, pe));
    }

    function test_settlementRefusedWithNoMeterRegistered() public {
        (SpendValidator.DayReadings memory r, SpendValidator.DayPrices memory p) = _flatDay(GENESIS, 100_000);
        vm.prank(owner);
        config.setMeter(address(0));

        vm.expectRevert(SpendValidator.SpendValidator_MeterNotRegistered.selector);
        validator.settleDay(r, p);
    }

    // ------------------------------------------------------------------
    // Only the oracle's prices
    // ------------------------------------------------------------------

    function test_unpublishedPricesAreRejected() public {
        uint64[48] memory imp;
        uint64[48] memory exp;
        int64[48] memory pi;
        int64[48] memory pe;
        SpendValidator.DayReadings memory r = _readings(GENESIS, imp, exp, meterKey);

        vm.expectRevert(abi.encodeWithSelector(SpendValidator.SpendValidator_PricesNotPublished.selector, GENESIS));
        validator.settleDay(r, SpendValidator.DayPrices(pi, pe));
    }

    /// A relayer inflating one export price -- more credit, less spend -- is
    /// refused.
    function test_alteredPricesAreRejected() public {
        (SpendValidator.DayReadings memory r, SpendValidator.DayPrices memory p) = _flatDay(GENESIS, 100_000);
        p.exportPrices[7] = p.exportPrices[7] + 1;

        vm.expectRevert(abi.encodeWithSelector(SpendValidator.SpendValidator_PricesMismatch.selector, GENESIS));
        validator.settleDay(r, p);
    }

    function test_settlementRefusedWithNoOracleRegistered() public {
        (SpendValidator.DayReadings memory r, SpendValidator.DayPrices memory p) = _flatDay(GENESIS, 100_000);
        vm.prank(owner);
        config.setPriceOracle(address(0));

        vm.expectRevert(SpendValidator.SpendValidator_OracleNotRegistered.selector);
        validator.settleDay(r, p);
    }

    // ------------------------------------------------------------------
    // Order: strictly past, strictly consecutive
    // ------------------------------------------------------------------

    function test_aDayCannotBeSettledBeforeItEnds() public {
        (SpendValidator.DayReadings memory r, SpendValidator.DayPrices memory p) = _flatDay(GENESIS, 100_000);
        vm.warp(uint256(GENESIS) * 86400 + 3600); // 01:00 on the day itself

        vm.expectRevert(abi.encodeWithSelector(SpendValidator.SpendValidator_DayNotEnded.selector, GENESIS, GENESIS));
        validator.settleDay(r, p);
    }

    /// A stranger cannot open the ledger at a later day and strand the days
    /// before it.
    function test_firstSettlementMustBeTheGenesisDay() public {
        (SpendValidator.DayReadings memory r, SpendValidator.DayPrices memory p) = _flatDay(GENESIS + 3, 100_000);

        vm.expectRevert(abi.encodeWithSelector(SpendValidator.SpendValidator_NotNextDay.selector, GENESIS + 3, GENESIS));
        validator.settleDay(r, p);
    }

    /// Skipping a day would make it permanently unrecordable, and it would
    /// count as zero -- headroom for the agent.
    function test_aDayCannotBeSkipped() public {
        _settleFlat(GENESIS, 100_000);
        (SpendValidator.DayReadings memory r, SpendValidator.DayPrices memory p) = _flatDay(GENESIS + 2, 100_000);

        vm.expectRevert(abi.encodeWithSelector(SpendValidator.SpendValidator_NotNextDay.selector, GENESIS + 2, GENESIS + 1));
        validator.settleDay(r, p);
    }

    function test_aDayCannotBeSettledTwice() public {
        (SpendValidator.DayReadings memory r, SpendValidator.DayPrices memory p) = _flatDay(GENESIS, 100_000);
        validator.settleDay(r, p);

        vm.expectRevert(abi.encodeWithSelector(SpendValidator.SpendValidator_NotNextDay.selector, GENESIS, GENESIS + 1));
        validator.settleDay(r, p);
        assertEq(ledger.netSpendOf(GENESIS), 480, "not accumulated a second time");
    }

    // ------------------------------------------------------------------
    // Over the cap: recorded, not refused
    // ------------------------------------------------------------------

    /// 300 Wh every half-hour at 1 USD/kWh is 14,400 milli-USD, over the
    /// 10,000 cap. Under the old submitDay this was reverted and left a hole
    /// that counted as zero. Measured energy is recorded (D7.5).
    function test_overCapDayIsRecordedNotRefused() public {
        uint64[48] memory imp;
        uint64[48] memory exp;
        int64[48] memory pi;
        int64[48] memory pe;
        for (uint256 i = 0; i < 48; i++) {
            imp[i] = 300_000;
            pi[i] = 100_000_000;
        }
        _publish(GENESIS, pi, pe);

        vm.recordLogs();
        validator.settleDay(_readings(GENESIS, imp, exp, meterKey), SpendValidator.DayPrices(pi, pe));

        assertEq(ledger.netSpendOf(GENESIS), 14400, "recorded in full");
        assertEq(validator.windowSum(GENESIS), 14400);

        Vm.Log[] memory logs = vm.getRecordedLogs();
        bool found;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] != SpendValidator.DaySettled.selector) continue;
            (int256 spend, int256 sum, int256 cap, bool compliant,) =
                abi.decode(logs[i].data, (int256, int256, int256, bool, uint256));
            assertEq(spend, 14400);
            assertEq(sum, 14400);
            assertEq(cap, CAP);
            assertFalse(compliant, "the event marks the breach");
            found = true;
        }
        assertTrue(found, "DaySettled emitted");
    }

    // ------------------------------------------------------------------
    // Gas, for the evaluation
    // ------------------------------------------------------------------

    function test_reportGasSettleOneDay() public {
        (SpendValidator.DayReadings memory r, SpendValidator.DayPrices memory p) = _flatDay(GENESIS, 100_000);
        uint256 before = gasleft();
        validator.settleDay(r, p);
        emit log_named_uint("gas, settle one day (verify, compute, record, window)", before - gasleft());
    }
}
