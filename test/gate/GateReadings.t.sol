// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import {Vm} from "forge-std/Vm.sol";
import {GateFixture} from "./GateFixture.sol";
import {OracleFixture} from "../oracle/OracleFixture.sol";
import {StubMarket} from "./mocks/GateMocks.sol";
import {FreshBatteryPolicy} from "./mocks/OracleMocks.sol";
import {PolicyGate} from "../../contracts/gate/PolicyGate.sol";
import {DecoderRegistry} from "../../contracts/gate/DecoderRegistry.sol";
import {OracleVerifier} from "../../contracts/oracle/OracleVerifier.sol";
import {ReadingKind, BmsReading, SignedReading} from "../../contracts/oracle/OracleTypes.sol";
import {CheckResult, Verdict} from "../../contracts/gate/GateTypes.sol";

/// @notice Readings handed in with an order (spec 4.1, step 3; step 5.1): the
///         gate has the oracle verifier accept them before any policy checks,
///         a bad reading stops the submission, and the agent cannot reach the
///         verifier's signer list.
contract GateReadingsTest is GateFixture, OracleFixture {
    bytes32 internal constant BATTERY_ID = keccak256("battery");
    uint64 internal constant MIN_SOC_WH = 1_000;

    OracleVerifier internal oracle;
    FreshBatteryPolicy internal battery;
    uint64 internal slotStart;

    event ReadingAccepted(
        address indexed account, ReadingKind indexed kind, address indexed signer, bytes32 digest, bytes data
    );
    event PolicyResult(
        address indexed account,
        bytes32 indexed orderHash,
        address indexed policy,
        bytes32 policyId,
        CheckResult result
    );

    function setUp() public override {
        super.setUp();
        oracle = gate.oracle();
        battery = new FreshBatteryPolicy();
        slotStart = uint64(block.timestamp) - 300;

        // Owner path: the account registers its BMS and adds the policy.
        vm.prank(owner);
        account.execute(
            address(oracle), 0, abi.encodeCall(oracle.setDevice, (ReadingKind.BMS, bmsSigner, BMS_MAX_AGE))
        );
        _asAccount(abi.encodeCall(gate.addPolicy, (battery, BATTERY_ID, abi.encode(MIN_SOC_WH))));
    }

    function _reading(uint64 timestamp, uint64 socWh) internal view returns (SignedReading[] memory one) {
        one = new SignedReading[](1);
        one[0] = _signBms(oracle, BMS_KEY, _bms(address(account), timestamp, socWh, 0));
    }

    function _submitWith(bytes memory callData, SignedReading[] memory readings) internal returns (bytes32) {
        vm.prank(agent);
        bytes memory result =
            account.executeAsSession(address(gate), abi.encodeCall(gate.submit, (address(market), callData, readings)));
        return result.length == 32 ? abi.decode(result, (bytes32)) : bytes32(0);
    }

    function _placed() internal view returns (uint256) {
        return market.orderCount();
    }

    // ------------------------------------------------------------------
    // Accepted
    // ------------------------------------------------------------------

    function test_aReadingBroughtWithTheOrderIsInPlaceBeforeThePoliciesCheck() public {
        SignedReading[] memory readings = _reading(slotStart, 3_300);
        vm.expectEmit(address(oracle));
        emit ReadingAccepted(
            address(account),
            ReadingKind.BMS,
            bmsSigner,
            _bmsDigest(oracle, _bms(address(account), slotStart, 3_300, 0)),
            readings[0].data
        );
        _submitWith(_order(1500), readings);

        // The policy saw the reading and let the order through.
        assertEq(_placed(), 1);
    }

    function test_thePolicySeesTheStoredEnergy() public {
        vm.recordLogs();
        bytes32 orderHash = _submitWith(_order(1500), _reading(slotStart, 3_300));
        CheckResult memory seen = _resultOf(orderHash, address(battery));
        assertEq(seen.valueAfter, 3_300);
        assertEq(uint8(seen.verdict), uint8(Verdict.EXECUTE));
    }

    function test_withoutAFreshReadingThePolicyRejects() public {
        _submitWith(_order(1500), new SignedReading[](0));
        assertEq(_placed(), 0);
    }

    function test_aReadingHandedInEarlierServesLaterOrdersWhileFresh() public {
        _submitWith(_order(1500), _reading(slotStart, 3_300));
        _submitWith(_order(1500), new SignedReading[](0));
        assertEq(_placed(), 2);

        vm.warp(slotStart + BMS_MAX_AGE + 1);
        _submitWith(_order(1500), new SignedReading[](0));
        assertEq(_placed(), 2);
    }

    function test_theSameReadingMayComeWithEveryOrderOfTheSlot() public {
        SignedReading[] memory readings = _reading(slotStart, 3_300);
        _submitWith(_order(1500), readings);
        _submitWith(_order(1500), readings);
        assertEq(_placed(), 2);
    }

    function test_aRejectionKeepsTheReadingItBrought() public {
        // Too little stored energy for the test policy: the order is refused,
        // but the genuine reading it brought stays accepted.
        _submitWith(_order(1500), _reading(slotStart, MIN_SOC_WH - 1));
        assertEq(_placed(), 0);
        (, bool fresh) = oracle.bmsOf(address(account));
        assertTrue(fresh);
    }

    // ------------------------------------------------------------------
    // Refused: the whole submission reverts
    // ------------------------------------------------------------------

    function test_aStaleReadingStopsTheSubmission() public {
        uint64 tooOld = uint64(block.timestamp) - BMS_MAX_AGE - 1;
        SignedReading[] memory readings = _reading(tooOld, 3_300);
        vm.expectRevert(
            abi.encodeWithSelector(OracleVerifier.Oracle_Stale.selector, tooOld, block.timestamp, BMS_MAX_AGE)
        );
        _submitWith(_order(1500), readings);
        assertEq(_placed(), 0);
        assertEq(gate.submissionCount(address(account)), 0);
    }

    function test_aReorderedReadingStopsTheSubmission() public {
        SignedReading[] memory older = _reading(slotStart - 60, 4_900);
        _submitWith(_order(1500), _reading(slotStart, 1_000));
        vm.expectRevert(abi.encodeWithSelector(OracleVerifier.Oracle_Reordered.selector, slotStart - 60, slotStart));
        _submitWith(_order(1500), older);
        assertEq(_placed(), 1);
    }

    function test_aForgedReadingStopsTheSubmission() public {
        SignedReading[] memory forged = new SignedReading[](1);
        forged[0] = _signBms(oracle, OTHER_KEY, _bms(address(account), slotStart, 4_900, 0));
        vm.expectRevert(
            abi.encodeWithSelector(OracleVerifier.Oracle_WrongSigner.selector, vm.addr(OTHER_KEY), bmsSigner)
        );
        _submitWith(_order(1500), forged);
    }

    function test_aReadingForAnotherAccountStopsTheSubmission() public {
        // The neighbour's own genuine reading, handed in by this account's agent.
        address neighbour = makeAddr("neighbour");
        vm.prank(neighbour);
        oracle.setDevice(ReadingKind.BMS, bmsSigner, BMS_MAX_AGE);
        SignedReading[] memory theirs = new SignedReading[](1);
        theirs[0] = _signBms(oracle, BMS_KEY, _bms(neighbour, slotStart, 4_900, 0));

        vm.expectRevert(abi.encodeWithSelector(PolicyGate.PolicyGate_ReadingForAnotherAccount.selector, neighbour));
        _submitWith(_order(1500), theirs);
    }

    function test_atMostFourReadingsPerSubmission() public {
        SignedReading[] memory five = new SignedReading[](5);
        vm.expectRevert(abi.encodeWithSelector(PolicyGate.PolicyGate_TooManyReadings.selector, 5));
        _submitWith(_order(1500), five);
    }

    // ------------------------------------------------------------------
    // The agent cannot reach the signer list
    // ------------------------------------------------------------------

    function test_theAgentCannotRegisterASignerThroughTheGate() public {
        bytes memory takeover =
            abi.encodeCall(OracleVerifier.setDevice, (ReadingKind.BMS, vm.addr(OTHER_KEY), BMS_MAX_AGE));
        vm.expectRevert(abi.encodeWithSelector(PolicyGate.PolicyGate_ForbiddenTarget.selector, address(oracle)));
        _submit(address(oracle), takeover);
    }

    function test_noDecoderCanBeApprovedForTheVerifierNorCanItBeTargeted() public {
        vm.expectRevert(
            abi.encodeWithSelector(DecoderRegistry.DecoderRegistry_ForbiddenTarget.selector, address(oracle))
        );
        _asAccount(abi.encodeCall(gate.setDecoder, (address(oracle), OracleVerifier.setDevice.selector, decoder)));
        bytes memory takeover =
            abi.encodeCall(OracleVerifier.setDevice, (ReadingKind.BMS, vm.addr(OTHER_KEY), BMS_MAX_AGE));
        vm.expectRevert(abi.encodeWithSelector(PolicyGate.PolicyGate_ForbiddenTarget.selector, address(oracle)));
        _submit(address(oracle), takeover);
        assertEq(oracle.deviceOf(address(account), ReadingKind.BMS).signer, bmsSigner);
    }

    function test_theAgentsSessionCannotCallTheVerifierDirectly() public {
        bytes memory takeover =
            abi.encodeCall(OracleVerifier.setDevice, (ReadingKind.BMS, vm.addr(OTHER_KEY), BMS_MAX_AGE));
        vm.prank(agent);
        vm.expectRevert();
        account.executeAsSession(address(oracle), takeover);
        assertEq(oracle.deviceOf(address(account), ReadingKind.BMS).signer, bmsSigner);
    }

    // ------------------------------------------------------------------

    function _resultOf(bytes32 orderHash, address policy_) internal returns (CheckResult memory) {
        bytes32 topic = keccak256("PolicyResult(address,bytes32,address,bytes32,(uint256,uint256,uint256,uint256,uint8))");
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i = 0; i < logs.length; ++i) {
            if (
                logs[i].topics[0] == topic && logs[i].topics[2] == orderHash
                    && address(uint160(uint256(logs[i].topics[3]))) == policy_
            ) {
                (, CheckResult memory r) = abi.decode(logs[i].data, (bytes32, CheckResult));
                return r;
            }
        }
        revert("no result");
    }
}
