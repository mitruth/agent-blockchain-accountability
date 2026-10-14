// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {PriceOracle} from "../../contracts/earlier-design/PriceOracle.sol";
import {PolicyConfig} from "../../contracts/earlier-design/PolicyConfig.sol";

/// Stage A1: the price oracle.
///
/// Prices are one of the two inputs daily spend is computed from, and neither
/// input may come from the agent (D7.1). What must hold:
///   - only the publisher publishes, and it is none of the other keys
///   - a published day is final
///   - settlement can prove a price vector is exactly what was published for
///     that day, and cannot pass off a vector for another day, a swapped
///     import/export pair, or a single altered half-hour
contract PriceOracleTest is Test {
    PriceOracle internal oracle;
    PolicyConfig internal config;

    address internal owner = makeAddr("owner");
    address internal agent = makeAddr("agentSessionKey");
    address internal guardian = makeAddr("guardian");
    address internal oracleAdmin = makeAddr("oracleAdmin");
    address internal publisher = makeAddr("pricePublisher");
    address internal stranger = makeAddr("stranger");

    uint64 internal constant DAY = 20000;

    int64[48] internal importPrices;
    int64[48] internal exportPrices;

    function setUp() public {
        vm.prank(oracleAdmin);
        oracle = new PriceOracle(publisher);

        vm.prank(owner);
        config = new PolicyConfig(guardian, agent, 10000, 7, 72 hours, 6 hours);

        // A plausible day in 1e-8 USD/kWh: 0.05 to ~0.12 USD/kWh, export at 30%.
        for (uint256 i = 0; i < 48; i++) {
            int64 p = int64(5_000_000 + int64(int256(i)) * 150_000);
            importPrices[i] = p;
            exportPrices[i] = (p * 3) / 10;
        }
    }

    function _publish() internal {
        vm.prank(publisher);
        oracle.publishDay(DAY, importPrices, exportPrices);
    }

    // ------------------------------------------------------------------
    // Publishing
    // ------------------------------------------------------------------

    function test_publisherIsItsOwnKey() public view {
        assertEq(oracle.publisher(), publisher);
        assertEq(oracle.admin(), oracleAdmin);
        assertTrue(publisher != owner && publisher != agent && publisher != guardian);
    }

    function test_publisherPublishesAndCommitmentIsStored() public {
        assertFalse(oracle.isPublished(DAY));
        _publish();

        assertTrue(oracle.isPublished(DAY));
        assertEq(oracle.commitmentOf(DAY), oracle.pricesCommitment(DAY, importPrices, exportPrices));
        assertTrue(oracle.verifyPrices(DAY, importPrices, exportPrices));
    }

    /// The prices themselves reach the chain, not only their hash: the event
    /// log is the archive a third party recomputes spend from.
    function test_publishedPricesAreEmittedInFull() public {
        vm.recordLogs();
        _publish();

        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(logs.length, 1);
        assertEq(logs[0].topics[0], PriceOracle.PricesPublished.selector);
        assertEq(uint256(logs[0].topics[1]), uint256(DAY));

        (bytes32 commitment, int64[48] memory imp, int64[48] memory exp) =
            abi.decode(logs[0].data, (bytes32, int64[48], int64[48]));
        assertEq(commitment, oracle.commitmentOf(DAY));
        for (uint256 i = 0; i < 48; i++) {
            assertEq(imp[i], importPrices[i]);
            assertEq(exp[i], exportPrices[i]);
        }
    }

    /// A published day is final. An amendable price would let a settled day's
    /// spend be rewritten after the fact.
    function test_aPublishedDayCannotBeRepublished() public {
        _publish();

        importPrices[0] = 1;
        vm.prank(publisher);
        vm.expectRevert(abi.encodeWithSelector(PriceOracle.PriceOracle_AlreadyPublished.selector, DAY));
        oracle.publishDay(DAY, importPrices, exportPrices);
    }

    function test_negativePricesArePublishable() public {
        importPrices[3] = -2_500_000; // -0.025 USD/kWh
        exportPrices[3] = 0;
        _publish();
        assertTrue(oracle.verifyPrices(DAY, importPrices, exportPrices));
    }

    // ------------------------------------------------------------------
    // Who may publish
    // ------------------------------------------------------------------

    function test_agentMayNotPublish() public {
        vm.prank(agent);
        vm.expectRevert(PriceOracle.PriceOracle_OnlyPublisher.selector);
        oracle.publishDay(DAY, importPrices, exportPrices);
    }

    function test_ownerMayNotPublish() public {
        vm.prank(owner);
        vm.expectRevert(PriceOracle.PriceOracle_OnlyPublisher.selector);
        oracle.publishDay(DAY, importPrices, exportPrices);
    }

    function test_guardianAndStrangerMayNotPublish() public {
        vm.prank(guardian);
        vm.expectRevert(PriceOracle.PriceOracle_OnlyPublisher.selector);
        oracle.publishDay(DAY, importPrices, exportPrices);

        vm.prank(stranger);
        vm.expectRevert(PriceOracle.PriceOracle_OnlyPublisher.selector);
        oracle.publishDay(DAY, importPrices, exportPrices);
    }

    function test_onlyAdminChoosesThePublisher() public {
        vm.prank(publisher);
        vm.expectRevert(PriceOracle.PriceOracle_OnlyAdmin.selector);
        oracle.setPublisher(agent);

        vm.prank(agent);
        vm.expectRevert(PriceOracle.PriceOracle_OnlyAdmin.selector);
        oracle.setPublisher(agent);

        vm.prank(owner);
        vm.expectRevert(PriceOracle.PriceOracle_OnlyAdmin.selector);
        oracle.setPublisher(owner);
    }

    function test_replacedPublisherMayNoLongerPublish() public {
        address newPublisher = makeAddr("newPublisher");
        vm.prank(oracleAdmin);
        oracle.setPublisher(newPublisher);

        vm.prank(publisher);
        vm.expectRevert(PriceOracle.PriceOracle_OnlyPublisher.selector);
        oracle.publishDay(DAY, importPrices, exportPrices);

        vm.prank(newPublisher);
        oracle.publishDay(DAY, importPrices, exportPrices);
        assertTrue(oracle.isPublished(DAY));
    }

    // ------------------------------------------------------------------
    // Verification cannot be fooled
    // ------------------------------------------------------------------

    function test_verifyRejectsAnUnpublishedDay() public view {
        assertFalse(oracle.verifyPrices(DAY, importPrices, exportPrices));
    }

    function test_verifyRejectsOneAlteredHalfHour() public {
        _publish();
        importPrices[47] = importPrices[47] - 1; // one unit of 1e-8 USD/kWh
        assertFalse(oracle.verifyPrices(DAY, importPrices, exportPrices));
    }

    /// Export prices are committed as tightly as import prices. Found by a
    /// mutation: a commitment over import prices only passed every other test,
    /// and would let a relayer inflate export prices -- more export credit,
    /// less measured spend -- without detection.
    function test_verifyRejectsOneAlteredExportPrice() public {
        _publish();
        exportPrices[20] = exportPrices[20] + 1;
        assertFalse(oracle.verifyPrices(DAY, importPrices, exportPrices));
    }

    function test_verifyRejectsImportAndExportSwapped() public {
        _publish();
        assertFalse(oracle.verifyPrices(DAY, exportPrices, importPrices));
    }

    /// The commitment binds the day. Yesterday's genuine prices are not valid
    /// for today, even if the publisher publishes identical vectors both days.
    function test_verifyRejectsAnotherDaysPrices() public {
        _publish();
        assertFalse(oracle.verifyPrices(DAY + 1, importPrices, exportPrices));
        assertTrue(
            oracle.pricesCommitment(DAY, importPrices, exportPrices)
                != oracle.pricesCommitment(DAY + 1, importPrices, exportPrices)
        );
    }

    // ------------------------------------------------------------------
    // The owner chooses the feed; nobody else does
    // ------------------------------------------------------------------

    function test_ownerRegistersThePriceOracle() public {
        vm.prank(owner);
        config.setPriceOracle(address(oracle));
        assertEq(config.priceOracle(), address(oracle));
    }

    function test_nobodyElseRegistersThePriceOracle() public {
        address rogue = makeAddr("rogueOracle");

        vm.prank(agent);
        vm.expectRevert(bytes("PolicyConfig: only owner"));
        config.setPriceOracle(rogue);

        vm.prank(guardian);
        vm.expectRevert(bytes("PolicyConfig: only owner"));
        config.setPriceOracle(rogue);

        vm.prank(publisher);
        vm.expectRevert(bytes("PolicyConfig: only owner"));
        config.setPriceOracle(rogue);

        assertEq(config.priceOracle(), address(0));
    }

    // ------------------------------------------------------------------
    // Gas, for the evaluation
    // ------------------------------------------------------------------

    function test_reportGasPublishOneDay() public {
        vm.prank(publisher);
        uint256 before = gasleft();
        oracle.publishDay(DAY, importPrices, exportPrices);
        emit log_named_uint("gas, publish one day of 96 prices", before - gasleft());
    }
}
