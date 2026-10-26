# Mutation run, every catalogue, 25–26 October 2026

`npm run mutate`, every catalogue, in Foundry's Docker image (`ghcr.io/foundry-rs/foundry:v1.8.5`).
The run went in three parts: gate, ledger and 54 of market's 55 mutants on 25 October;
market's last mutant and 26 of window's 35 that evening, when the detached run died overnight;
and window again in full, then every later catalogue, on 26 October (186 minutes).
Merged from the three logs; a mutant run twice keeps its later verdict.

492 mutants: 489 caught, 3 accepted.

| Catalogue | Mutants | Run | Caught | Accepted |
|---|---:|---:|---:|---:|
| gate | 43 | 43 | 43 | 0 |
| ledger | 51 | 51 | 48 | 3 |
| market | 55 | 55 | 55 | 0 |
| window | 35 | 35 | 35 | 0 |
| policies | 53 | 53 | 53 | 0 |
| physical | 47 | 47 | 47 | 0 |
| oracle2 | 34 | 34 | 34 | 0 |
| breaker | 45 | 45 | 45 | 0 |
| price | 30 | 30 | 30 | 0 |
| roundtrip | 20 | 20 | 20 | 0 |
| delivery | 37 | 37 | 37 | 0 |
| envelope | 18 | 18 | 18 | 0 |
| gridstate | 15 | 15 | 15 | 0 |
| accounts | 9 | 9 | 9 | 0 |

An accepted mutant is one the catalogue declares out of scope with its reason: the three here
are faults in a test double (the mock market or its decoder) of `test/gate/`, not in the system.
The real market and its decoder have their own catalogue, `market`, where every mutant is caught.

| Catalogue | Mutant | Verdict | Caught by |
|---|---|---|---|
| gate | submit open to any caller | caught | tests: 2 failing, e.g. KeyModelTest.test_onlyAnAccountWithTheGateInstalledMaySubmit |
| gate | submit: forbidden-target check removed | caught | tests: 3 failing, e.g. KeyModelTest.test_accountIsNeverATargetWhateverTheCall |
| gate | setDecoder: forbidden-target check removed | caught | tests: 1 failing, e.g. KeyModelTest.test_ownerCannotApproveTheAccountOrTheGateAsATarget |
| gate | account allowed as target everywhere | caught | tests: 2 failing, e.g. KeyModelTest.test_accountIsNeverATargetWhateverTheCall |
| gate | gate allowed as target everywhere | caught | tests: 2 failing, e.g. KeyModelTest.test_gateIsNeverATargetWhateverTheCall |
| gate | unknown-call check removed | caught | tests: 5 failing, e.g. KeyModelTest.test_removingAnApprovalTakesEffectAtOnce |
| gate | zero decoder accepted | caught | tests: 1 failing, e.g. KeyModelTest.test_ownerCannotRegisterAZeroDecoder |
| gate | removeDecoder is a no-op | caught | tests: 1 failing, e.g. KeyModelTest.test_removingAnApprovalTakesEffectAtOnce |
| gate | short calldata check removed | caught | tests: 1 failing, e.g. KeyModelTest.test_callDataShorterThanASelectorIsRejected |
| gate | owner path open to anyone | caught | tests: 5 failing, e.g. ConfigManagerTest.test_agentCannotApplyAnOwnerProposal |
| gate | reentrancy lock removed | caught | tests: 1 failing, e.g. KeyModelTest.test_targetCannotReenterTheGate |
| gate | generation not bumped | caught | tests: 1 failing, e.g. KeyModelTest.test_uninstallStopsTheAgentAndReinstallStartsEmpty |
| gate | double install allowed | caught | tests: 1 failing, e.g. KeyModelTest.test_installTwiceIsRefused |
| gate | uninstall leaves installed | caught | tests: 2 failing, e.g. KeyModelTest.test_uninstallStopsTheAgentAndReinstallStartsEmpty |
| gate | submission count not advanced | caught | tests: 2 failing, e.g. KeyModelTest.test_orderHashesAreDistinctForIdenticalCalls |
| gate | executor claims validator type | caught | tests: 1 failing, e.g. KeyModelTest.test_gateReportsItselfAsAnExecutorOnly |
| gate | uninstall skips deconfigure | caught | tests: 1 failing, e.g. KeyModelTest.test_uninstallStopsTheAgentAndReinstallStartsEmpty |
| gate | uninstall deconfigure not swallowed | caught | tests: 1 failing, e.g. KeyModelTest.test_uninstallSucceedsEvenIfAPolicyRefusesToLetGo |
| gate | value sent with the call | caught | tests: 9 failing, e.g. KeyModelTest.test_aRevertingMarketCallRevertsTheWholeSubmission |
| gate | market call skipped | caught | tests: 8 failing, e.g. KeyModelTest.test_aRevertingMarketCallRevertsTheWholeSubmission |
| gate | widening applies at once | caught | tests: 12 failing, e.g. ConfigManagerTest.test_aLaterTighteningDropsThePendingWidening |
| gate | config timelock removed | caught | tests: 2 failing, e.g. ConfigManagerTest.test_aNewProposalRestartsTheTimelock |
| gate | config timelock one second long | caught | tests |
| gate | config hash check removed | caught | tests: 1 failing, e.g. ConfigManagerTest.test_applyRequiresTheProposedConfigByteForByte |
| gate | widen delay 23h | caught | tests: 1 failing, e.g. ConfigManagerTest.test_wideningDelayIsTwentyFourHours |
| gate | pending survives a later write | caught | tests: 1 failing, e.g. ConfigManagerTest.test_aLaterTighteningDropsThePendingWidening |
| gate | proposal not spent on apply | caught | tests: 1 failing, e.g. ConfigManagerTest.test_wideningAppliesOnceTheDelayHasRun |
| gate | invalid config applied by setConfig | caught | tests: 1 failing, e.g. ConfigManagerTest.test_invalidConfigIsRejectedAndChangesNothing |
| gate | invalid config accepted by addPolicy | caught | tests: 1 failing, e.g. ConfigManagerTest.test_addPolicyWithInvalidConfigIsRejectedAndNotAdded |
| gate | removal timelock removed | caught | tests: 1 failing, e.g. ConfigManagerTest.test_removalWaitsTheDelay |
| gate | removal timelock one second long | caught | tests |
| gate | removal accepts a config proposal | caught | tests: 1 failing, e.g. ConfigManagerTest.test_proposalKindsAreNotInterchangeable |
| gate | apply accepts a removal proposal | caught | tests: 1 failing, e.g. ConfigManagerTest.test_proposalKindsAreNotInterchangeable |
| gate | policy bound off by one | caught | tests: 1 failing, e.g. ConfigManagerTest.test_policyListIsBounded |
| gate | duplicate policy allowed | caught | tests: 1 failing, e.g. ConfigManagerTest.test_addingTheSameInstanceTwiceIsRefused |
| gate | moved entry index not updated | caught | tests: 1 failing, e.g. ConfigManagerTest.test_removingOneInstanceKeepsTheOthersFindable |
| gate | removal deconfigure not swallowed | caught | tests: 1 failing, e.g. ConfigManagerTest.test_aPolicyThatRefusesToLetGoIsStillRemoved |
| gate | removal skips deconfigure | caught | tests: 1 failing, e.g. ConfigManagerTest.test_removalWaitsTheDelay |
| gate | cancel is a no-op | caught | tests: 1 failing, e.g. ConfigManagerTest.test_cancelDropsTheProposal |
| gate | unknown policy configurable | caught | tests: 2 failing, e.g. ConfigManagerTest.test_anotherAccountCannotConfigureThisOne |
| gate | policy may be the account | caught | tests: 1 failing, e.g. ConfigManagerTest.test_addPolicyRefusesTheAccountTheGateAndZero |
| gate | policy may be the gate | caught | tests: 1 failing, e.g. ConfigManagerTest.test_addPolicyRefusesTheAccountTheGateAndZero |
| gate | removal proposal does not drop pending config | caught | tests: 1 failing, e.g. ConfigManagerTest.test_removalProposalSupersedesAPendingWidening |
| ledger | place: committed buy not added | caught | tests: 22 failing, e.g. PositionLedgerTest.test_anOrderIsBookedOnce |
| ledger | place: committed sell not added | caught | tests: 2 failing, e.g. GatedMarketTest.test_offersThroughTheGateAreBookedAsSells |
| ledger | place: sides swapped | caught | tests: 24 failing, e.g. PositionLedgerTest.test_anOrderIsBookedOnce |
| ledger | bound off by one | caught | tests: 1 failing, e.g. OrderLifecycleTest.test_openOrdersAreBounded |
| ledger | bound removed | caught | tests: 1 failing, e.g. OrderLifecycleTest.test_openOrdersAreBounded |
| ledger | bound 63 | caught | tests: 1 failing, e.g. PositionLedgerTest.test_theOpenOrderBoundIsSixtyFour |
| ledger | open count not incremented | caught | tests: 24 failing, e.g. PositionLedgerTest.test_anOrderIsBookedOnce |
| ledger | open count not decremented | caught | tests: 8 failing, e.g. GatedMarketTest.test_aCancelThroughTheGateReleasesInTheMarketAndTheLedger |
| ledger | duplicate record allowed | caught | tests: 1 failing, e.g. PositionLedgerTest.test_anOrderIsBookedOnce |
| ledger | non-placement leg booked as placement | caught | tests: 1 failing, e.g. PositionLedgerTest.test_onlyAPlacementLegIsBookedAsAPlacement |
| ledger | zero quantity booked | caught | tests: 1 failing, e.g. PositionLedgerTest.test_aZeroQuantityIsNotBooked |
| ledger | placement time not recorded | caught | tests: 1 failing, e.g. OrderLifecycleTest.test_placeBooksACommittedBuy |
| ledger | fill: cleared buy not added | caught | tests: 7 failing, e.g. PositionLedgerTest.test_aFillThatGoesBackwardsIsRefused |
| ledger | fill: cleared sell not added | caught | tests |
| ledger | fill: sides swapped | caught | tests: 7 failing, e.g. PositionLedgerTest.test_aFillThatGoesBackwardsIsRefused |
| ledger | fill: booked total not stored | caught | tests: 7 failing, e.g. PositionLedgerTest.test_aFillThatGoesBackwardsIsRefused |
| ledger | fill: inconsistency check removed | caught | tests: 2 failing, e.g. PositionLedgerTest.test_aFillBeyondTheOrderIsRefused |
| ledger | full fill not closed | caught | tests: 2 failing, e.g. OrderLifecycleTest.test_fullFillClosesTheOrderAndReleasesNothing |
| ledger | expiry never | caught | tests: 2 failing, e.g. GatedMarketTest.test_fillsAreBookedOnReconcileAndTheRestExpiresAtFinalisation |
| ledger | closed elsewhere never | caught | tests: 2 failing, e.g. OrderLifecycleTest.test_anOrderClosedOutsideTheGateIsReleasedWithItsOwnReason |
| ledger | expiry reported as cancellation | caught | tests: 2 failing, e.g. OrderLifecycleTest.test_expiryReleasesTheUnfilledPartAtGateClosure |
| ledger | cancellation reported as expiry | caught | tests: 1 failing, e.g. OrderLifecycleTest.test_cancelReleasesTheUnfilledOrder |
| ledger | release not subtracted | caught | tests: 12 failing, e.g. GatedMarketTest.test_aCancelThroughTheGateReleasesInTheMarketAndTheLedger |
| ledger | release: sides swapped | caught | tests: 16 failing, e.g. GatedMarketTest.test_aCancelThroughTheGateReleasesInTheMarketAndTheLedger |
| ledger | release whole quantity, fill ignored | caught | tests: 6 failing, e.g. GatedMarketTest.test_aFullyMatchedOrderClosesAsFilled |
| ledger | cancel skips booking fills | caught | tests: 2 failing, e.g. OrderLifecycleTest.test_cancelAfterAnUnbookedPartialFillBooksTheFillFirst |
| ledger | closed order still open | caught | tests: 4 failing, e.g. GatedMarketTest.test_aCancelThroughTheGateReleasesInTheMarketAndTheLedger |
| ledger | closed order reconcilable | caught | tests: 2 failing, e.g. OrderLifecycleTest.test_agentCannotCancelAnOrderThatWasNotPlacedThroughTheGate |
| ledger | writer check removed | caught | tests: 4 failing, e.g. PositionLedgerTest.test_aWithdrawnWriterCanNoLongerWrite |
| ledger | setWriter ignores withdrawal | caught | tests: 1 failing, e.g. PositionLedgerTest.test_aWithdrawnWriterCanNoLongerWrite |
| ledger | ledger allowed as target | caught | tests: 2 failing, e.g. KeyModelTest.test_ledgerIsNeverATarget |
| ledger | cancel legs not booked | caught | tests: 11 failing, e.g. GatedMarketTest.test_aCancelThroughTheGateReleasesInTheMarketAndTheLedger |
| ledger | place legs not booked | caught | tests: 26 failing, e.g. GatedMarketTest.test_aCancelThroughTheGateReleasesInTheMarketAndTheLedger |
| ledger | empty decode accepted | caught | tests: 1 failing, e.g. KeyModelTest.test_aCallWithNoLegsOrTooManyIsRejected |
| ledger | leg limit ignored | caught | tests: 2 failing, e.g. KeyModelTest.test_aCallWithNoLegsOrTooManyIsRejected |
| ledger | gate reconcile does nothing | caught | tests: 10 failing, e.g. GatedMarketTest.test_aFullyMatchedOrderClosesAsFilled |
| ledger | reconcile event dropped | caught | tests: 1 failing, e.g. OrderLifecycleTest.test_partialFillIsBookedOnReconcile |
| ledger | cancel leg: full quantity, not unfilled | caught | tests: 2 failing, e.g. OrderLifecycleTest.test_cancelAfterAnUnbookedPartialFillBooksTheFillFirst |
| ledger | value rounds down | caught | tests: 1 failing, e.g. OrderLifecycleTest.test_placementIsValuedAtTheLimitPriceRoundedUp |
| ledger | value overflow unchecked | caught | tests: 1 failing, e.g. OrderLifecycleTest.test_aValueBeyondTheTypeIsRefused |
| ledger | modify legs in wrong order | caught | tests: 2 failing, e.g. OrderLifecycleTest.test_modifyDecodesAsCancelThenPlace |
| ledger | modify keeps BUY whatever the side | accepted | a fault in a test double of test/gate/ (the mock market or its decoder), not in the system; the real market and its decoder have their own catalogue |
| ledger | fill state: open always true | caught | tests: 3 failing, e.g. OrderLifecycleTest.test_anOrderClosedOutsideTheGateIsReleasedWithItsOwnReason |
| ledger | gate closes at slot start | accepted | a fault in a test double of test/gate/ (the mock market or its decoder), not in the system; the real market and its decoder have their own catalogue |
| ledger | placement allowed at gate closure | caught | tests: 1 failing, e.g. OrderLifecycleTest.test_noPlacementAtOrAfterGateClosure |
| ledger | fill past gate | caught | tests: 3 failing, e.g. OrderLifecycleTest.test_anUnfilledOrderExpiresEntirely |
| ledger | buy limit flipped | caught | tests: 1 failing, e.g. OrderLifecycleTest.test_fillsRespectTheLimitPriceAndTheQuantity |
| ledger | over-fill allowed | caught | tests: 1 failing, e.g. OrderLifecycleTest.test_fillsRespectTheLimitPriceAndTheQuantity |
| ledger | anyone fills | caught | tests: 1 failing, e.g. OrderLifecycleTest.test_fillsRespectTheLimitPriceAndTheQuantity |
| ledger | cancelled order still open | caught | tests: 1 failing, e.g. OrderLifecycleTest.test_anOrderClosedOutsideTheGateIsReleasedWithItsOwnReason |
| ledger | anyone cancels | accepted | a fault in a test double of test/gate/ (the mock market or its decoder), not in the system; the real market and its decoder have their own catalogue |
| market | token: allowance not checked | caught | tests: 1 failing, e.g. LockableERC1155Test.test_aStrangerCannotLockSomeoneElsesBalance |
| market | token: allowance not used up | caught | tests: 1 failing, e.g. LockableERC1155Test.test_aLockerUsesUpTheOwnersAllowance |
| market | token: lock beyond unlocked | caught | tests: 2 failing, e.g. LockableERC1155Test.test_nothingBeyondTheUnlockedBalanceIsLocked |
| market | token: locked balance movable | caught | tests: 3 failing, e.g. LockableERC1155Test.test_anOperatorApprovedForAllCannotMoveLockedPayment |
| market | token: anyone mints payment | caught | tests: 1 failing, e.g. LockableERC1155Test.test_onlyTheIssuerMintsPayment |
| market | token: anyone mints energy | caught | tests: 1 failing, e.g. LockableERC1155Test.test_onlyAnAppointedMinterMintsEnergy |
| market | token: anyone burns energy | caught | tests: 1 failing, e.g. LockableERC1155Test.test_energyIsBurnedByItsHolderOrAnApprovedOperatorOnly |
| market | token: payment burnable | caught | tests: 1 failing, e.g. LockableERC1155Test.test_paymentCannotBeBurned |
| market | token: release beyond lock | caught | tests: 2 failing, e.g. LockableERC1155Test.test_aLockIsTiedToItsOwner |
| market | token: locked total not reduced | caught | tests: 14 failing, e.g. LockableERC1155Test.test_theUnlockerReleasesAsAPayment |
| market | session: unregistered may place | caught | tests: 1 failing, e.g. MarketFlowTest.test_onlyRegisteredProsumersPlaceInASession |
| market | session: place at closing time | caught | tests: 1 failing, e.g. MarketFlowTest.test_noOrderOnceTheSessionHasClosed |
| market | session: cancel after close | caught | tests: 1 failing, e.g. MarketFlowTest.test_noCancelOnceTheSessionHasClosed |
| market | session: anyone cancels | caught | tests: 1 failing, e.g. MarketFlowTest.test_onlyTheOrdersProsumerCancelsItInTheSession |
| market | session: anyone registers trades | caught | tests: 1 failing, e.g. MarketFlowTest.test_onlyTheMatcherRegistersTrades |
| market | session: trades before close | caught | tests: 1 failing, e.g. MarketFlowTest.test_noTradeBeforeTheSessionCloses |
| market | session: bid limit ignored | caught | tests: 1 failing, e.g. MarketFlowTest.test_aTradeOutsideEitherLimitPriceIsRefused |
| market | session: offer limit ignored | caught | tests: 1 failing, e.g. MarketFlowTest.test_aTradeOutsideEitherLimitPriceIsRefused |
| market | session: self-trade allowed | caught | tests: 1 failing, e.g. MarketFlowTest.test_anAccountCannotTradeWithItself |
| market | session: cross-slot trade allowed | caught | tests: 1 failing, e.g. MarketFlowTest.test_aTradeAcrossSlotsIsRefused |
| market | session: bid over-match allowed | caught | tests: 1 failing, e.g. MarketFlowTest.test_aTradeBeyondTheBidIsRefused |
| market | session: offer over-match allowed | caught | tests |
| market | session: cancelled bid matchable | caught | tests: 1 failing, e.g. MarketFlowTest.test_aCancelledOrderCannotBeMatched |
| market | session: anyone finalises | caught | tests: 1 failing, e.g. MarketFlowTest.test_onlyTheMatcherOrTheOperatorFinalises |
| market | session: expire before finalisation | caught | tests: 1 failing, e.g. MarketFlowTest.test_nothingExpiresBeforeFinalisation |
| market | session: fully matched order expires | caught | tests: 1 failing, e.g. MarketFlowTest.test_aFullyMatchedOrderHasNothingToExpire |
| market | session: ids repeat across sessions | caught | tests: 1 failing, e.g. MarketFlowTest.test_orderIdsAreUniqueAcrossSessions |
| market | session: no trade after finalisation not enforced | caught | tests: 1 failing, e.g. MarketFlowTest.test_noTradeAfterFinalisation |
| market | prosumer: anyone places | caught | tests: 2 failing, e.g. GatedMarketTest.test_theAgentHasNoDirectRouteIntoTheMarket |
| market | prosumer: anyone calls back | caught | tests: 2 failing, e.g. MarketFlowTest.test_onlyTheOrdersSessionCallsBack |
| market | prosumer: offer collateral at its own price | caught | tests: 6 failing, e.g. MarketFlowTest.test_aDeliveryWithinTenPercentCostsNothing |
| market | prosumer: bid pays at limit | caught | tests: 5 failing, e.g. MarketFlowTest.test_aBuyersPenaltyComesFromItsBalance |
| market | prosumer: full bid keeps over-reservation | caught | tests: 3 failing, e.g. GatedMarketTest.test_C5_theMarketChargesNoFeeBeyondWhatS1Counts |
| market | prosumer: delivery collateral not held | caught | tests: 3 failing, e.g. MarketFlowTest.test_aDeliveryWithinTenPercentCostsNothing |
| market | prosumer: expiry keeps energy | caught | tests: 1 failing, e.g. MarketFlowTest.test_expiryReleasesTheUnmatchedPartAndBurnsUnmatchedEnergy |
| market | prosumer: cancel keeps collateral | caught | tests: 4 failing, e.g. MarketFlowTest.test_cancelReleasesCollateralAndBurnsTheOffersEnergy |
| market | prosumer: anyone settles | caught | tests: 1 failing, e.g. MarketFlowTest.test_onlyTheProsumersSensorSettles |
| market | prosumer: settle before slot ends | caught | tests: 1 failing, e.g. MarketFlowTest.test_aSlotIsSettledOnceAndOnlyAfterItEnds |
| market | prosumer: settle twice | caught | tests: 1 failing, e.g. MarketFlowTest.test_aSlotIsSettledOnceAndOnlyAfterItEnds |
| market | prosumer: no penalty from balance | caught | tests: 1 failing, e.g. MarketFlowTest.test_aBuyersPenaltyComesFromItsBalance |
| market | prosumer: collateral not released after settlement | caught | tests: 2 failing, e.g. MarketFlowTest.test_aDeliveryWithinTenPercentCostsNothing |
| market | prosumer: net sign flipped | caught | tests: 3 failing, e.g. MarketFlowTest.test_aBuyersPenaltyComesFromItsBalance |
| market | manager: no minter appointed | caught | tests: 28 failing, e.g. GatedMarketTest.test_C5_theMarketChargesNoFeeBeyondWhatS1Counts |
| market | manager: session may close after delivery | caught | tests: 1 failing, e.g. MarketFlowTest.test_aSessionMustCloseBeforeDeliveryAndHaveSlots |
| market | manager: anyone operates | caught | tests: 1 failing, e.g. MarketFlowTest.test_onlyTheOperatorRunsTheManager |
| market | manager: slot bound 97 | caught | tests: 1 failing, e.g. MarketFlowTest.test_aSessionMustCloseBeforeDeliveryAndHaveSlots |
| market | settlement: threshold inclusive flipped | caught | tests: 1 failing, e.g. ClassicSettlementTest.test_exactlyTenPercentCostsNothing |
| market | settlement: threshold 20% | caught | tests: 4 failing, e.g. ClassicSettlementTest.test_aPenaltyRoundsUp |
| market | settlement: penalty rounds down | caught | tests: 1 failing, e.g. ClassicSettlementTest.test_aPenaltyRoundsUp |
| market | decoder: open ignores finalisation | caught | tests: 1 failing, e.g. GatedMarketTest.test_fillsAreBookedOnReconcileAndTheRestExpiresAtFinalisation |
| market | decoder: expiry ignores finalisation | caught | tests: 1 failing, e.g. GatedMarketTest.test_fillsAreBookedOnReconcileAndTheRestExpiresAtFinalisation |
| market | decoder: sides swapped | caught | tests: 4 failing, e.g. GatedMarketTest.test_C5_theMarketChargesNoFeeBeyondWhatS1Counts |
| market | decoder: slot within session, not on grid | caught | tests: 4 failing, e.g. GatedMarketTest.test_aDayAheadBatchIsTwentyFourLegs |
| market | decoder: value rounds down | caught | tests: 1 failing, e.g. GatedMarketTest.test_legValuesRoundUp |
| market | valuation rounds to nearest, not up (spec 8: rounding switched) | caught | tests: 2 failing, e.g. ClassicSettlementTest.test_aPenaltyRoundsUp |
| window | cap comparison <= becomes < (spec 8) | caught | tests + verifier: 10 failing, e.g. WindowLibTest.test_aBoundaryBurstAdmitsTwiceTheCapUnderTumblingAndOnceUnderSliding |
| window | bucket index off by one (spec 8) | caught | tests + verifier: 11 failing, e.g. WindowLibTest.test_aBoundaryBurstAdmitsTwiceTheCapUnderTumblingAndOnceUnderSliding |
| window | window start shifted one bucket later, read (spec 8) | caught | tests + verifier: 1 failing, e.g. WindowLibTest.test_slidingAdvancesItsStoredStateOnWrite |
| window | window start shifted one bucket later, write (spec 8) | caught | tests + verifier: 3 failing, e.g. WindowLibTest.test_aCreditOutsideTheWindowIsIgnored |
| window | window start shifted one bucket earlier, read (spec 8) | caught | tests + verifier: 5 failing, e.g. WindowLibTest.test_aBoundaryBurstAdmitsTwiceTheCapUnderTumblingAndOnceUnderSliding |
| window | window start shifted one bucket earlier, write (spec 8) | caught | tests + verifier: 8 failing, e.g. WindowLibTest.test_aCreditInTheLastSecondOfTheWindowApplies |
| window | credit to the current bucket instead of the original (spec 8) | caught | tests + verifier: 4 failing, e.g. WindowLibTest.test_aCreditInTheLastSecondOfTheWindowApplies |
| window | credit applied outside the window (spec 8) | caught | tests + verifier |
| window | credit applied one bucket beyond the window (spec 8) | caught | tests |
| window | generation not bumped on full reset (spec 8) | caught | tests + verifier: 1 failing, e.g. WindowLibTest.test_slidingResetsLazilyAfterALongIdleGap |
| window | restart does not bump the generation | caught | tests: 1 failing, e.g. WindowLibTest.test_aRestartLeavesNothingOfTheOldRing |
| window | the writing sweep does not clear what expired | caught | tests + verifier: 1 failing, e.g. WindowLibTest.test_slidingAdvancesItsStoredStateOnWrite |
| window | the read-only sweep reads the wrong storage word | caught | tests + verifier: 1 failing, e.g. WindowLibTest.test_theWorstCaseSweepOfAWeekOfHourlyBucketsIsBounded |
| window | a lane is read from the wrong position | caught | tests + verifier: 4 failing, e.g. WindowLibTest.test_aCreditNeverTakesABucketBelowZero |
| window | writing a lane does not clear its old value | caught | tests + verifier: 2 failing, e.g. WindowLibTest.test_aCreditNeverTakesABucketBelowZero |
| window | sliding mark not advanced on write | caught | tests + verifier: 13 failing, e.g. WindowLibTest.test_aBoundaryBurstAdmitsTwiceTheCapUnderTumblingAndOnceUnderSliding |
| window | a credit may take a bucket below zero | caught | tests: 1 failing, e.g. WindowLibTest.test_aCreditNeverTakesABucketBelowZero |
| window | a credit dated in the future is accepted | caught | tests: 1 failing, e.g. WindowLibTest.test_aCreditDatedInTheFutureIsIgnored |
| window | tumbling never restarts | caught | tests + verifier: 1 failing, e.g. WindowLibTest.test_tumblingCreditsOnlyWithinThePeriod |
| window | tumbling count read without its period | caught | tests + verifier: 3 failing, e.g. WindowLibTest.test_aBoundaryBurstAdmitsTwiceTheCapUnderTumblingAndOnceUnderSliding |
| window | tumbling credit across periods | caught | tests + verifier: 1 failing, e.g. WindowLibTest.test_tumblingCreditsOnlyWithinThePeriod |
| window | tumbling periods anchored at zero, not at the anchor | caught | tests + verifier: 1 failing, e.g. WindowLibTest.test_tumblingRestartsAtEachPeriodBoundary |
| window | refill credit across intervals: the double refund | caught | tests + verifier: 1 failing, e.g. WindowLibTest.test_refillCreditsOnlyWithinTheSameInterval |
| window | refill one interval late | caught | tests + verifier: 2 failing, e.g. WindowLibTest.test_refillCreditsOnlyWithinTheSameInterval |
| window | refill count read without the refills since | caught | tests + verifier: 2 failing, e.g. WindowLibTest.test_refillGivesBackItsRateEachInterval |
| window | refill mark not advanced: refills counted twice | caught | tests + verifier: 3 failing, e.g. WindowLibTest.test_refillCreditsOnlyWithinTheSameInterval |
| window | stream not capped | caught | tests + verifier: 1 failing, e.g. WindowLibTest.test_streamUnlocksOverTime |
| window | stream unlocks one interval early | caught | tests + verifier: 1 failing, e.g. WindowLibTest.test_streamUnlocksOverTime |
| window | every class limited as a stream | caught | tests + verifier: 18 failing, e.g. WindowLibTest.test_aBoundaryBurstAdmitsTwiceTheCapUnderTumblingAndOnceUnderSliding |
| window | a count beyond 64 bits wraps | caught | tests: 1 failing, e.g. WindowLibTest.test_aCountBeyondSixtyFourBitsReverts |
| window | a change of shape keeps the count | caught | tests: 2 failing, e.g. WindowLibTest.test_aChangeOfShapeStartsAfreshAndAChangeOfCapDoesNot |
| window | the bucket count is not part of the shape | caught | tests: 2 failing, e.g. WindowLibTest.test_aChangeOfShapeStartsAfreshAndAChangeOfCapDoesNot |
| window | the most buckets allowed is exclusive | caught | tests: 1 failing, e.g. WindowLibTest.test_malformedConfigurationsAreRefused |
| window | zero buckets accepted | caught | tests: 1 failing, e.g. WindowLibTest.test_malformedConfigurationsAreRefused |
| window | a stream starting above its cap accepted | caught | tests: 1 failing, e.g. WindowLibTest.test_malformedConfigurationsAreRefused |
| policies | a rejection does not stop the submission | caught | tests: 5 failing, e.g. PolicyPhasesTest.test_aModificationNeedsRoomForTheNewOrderBeforeTheOldIsCredited |
| policies | a flag is taken for a rejection | caught | tests: 5 failing, e.g. PolicyPhasesTest.test_aCancellationAtTheHardBoundPassesAndIsCredited |
| policies | the check stops at the first rejection | caught | tests: 1 failing, e.g. PolicyPhasesTest.test_aRejectionByOneInstanceStopsAllAndEveryResultIsLogged |
| policies | a flag is not emitted | caught | tests: 1 failing, e.g. PolicyPhasesTest.test_aSoftBoundCrossedIsFlaggedAndExecuted |
| policies | the commit phase is skipped | caught | tests: 10 failing, e.g. PolicyPhasesTest.test_aFailingCreditDoesNotBlockReconciliation |
| policies | a cancellation is not credited | caught | tests: 3 failing, e.g. PolicyPhasesTest.test_aCancellationAtTheHardBoundPassesAndIsCredited |
| policies | a release on reconcile is not credited | caught | tests: 2 failing, e.g. PolicyPhasesTest.test_aFailingCreditDoesNotBlockReconciliation |
| policies | a failing credit blocks reconciliation | caught | tests: 1 failing, e.g. PolicyPhasesTest.test_aFailingCreditDoesNotBlockReconciliation |
| policies | the whole order is released, fills included | caught | tests: 1 failing, e.g. PolicyPhasesTest.test_aPartlyFilledCancellationCreditsOnlyTheUnfilledPart |
| policies | a credit goes to the current bucket, not the placement's | caught | tests: 1 failing, e.g. PolicyPhasesTest.test_aCancellationAtTheHardBoundPassesAndIsCredited |
| policies | A1 exclusive: <= becomes < on a policy's cap comparison (spec 8) | caught | tests: 3 failing, e.g. StaticOrderPolicyTest.test_A1_quantityIsBoundedInclusively |
| policies | A1 rated-power term exclusive | caught | tests: 2 failing, e.g. StaticOrderPolicyTest.test_A1_ratedPowerBoundsTheQuantityInclusively |
| policies | A1 rated-power term dropped | caught | tests: 2 failing, e.g. StaticOrderPolicyTest.test_A1_ratedPowerBoundsTheQuantityInclusively |
| policies | A1 rated-power term rounded up | caught | tests: 1 failing, e.g. StaticOrderPolicyTest.test_A1_ratedPowerRoundsDown |
| policies | A1 rated-power term over the next slot's length, off by one | caught | tests: 2 failing, e.g. StaticOrderPolicyTest.test_A1_ratedPowerBoundsTheQuantityInclusively |
| policies | A1 minimum exclusive | caught | tests: 1 failing, e.g. StaticOrderPolicyTest.test_A1_minimumQuantityIsBoundedInclusively |
| policies | A1 minimum not checked | caught | tests: 1 failing, e.g. StaticOrderPolicyTest.test_A1_minimumQuantityIsBoundedInclusively |
| policies | A1 a higher rated power is not a widening | caught | tests: 1 failing, e.g. StaticOrderPolicyTest.test_everyLooserParameterIsAWidening |
| policies | A1 a lower minimum is not a widening | caught | tests: 1 failing, e.g. StaticOrderPolicyTest.test_aLowerMinimumIsAWidening |
| policies | A1 a minimum at the maximum is invalid | caught | tests: 1 failing, e.g. StaticOrderPolicyTest.test_aMalformedConfigurationIsInvalid |
| policies | A1 a zero rated power is valid | caught | tests: 1 failing, e.g. StaticOrderPolicyTest.test_aMalformedConfigurationIsInvalid |
| policies | A2 exclusive | caught | tests: 2 failing, e.g. StaticOrderPolicyTest.test_A2_valueIsBoundedInclusively |
| policies | A3 floor and ceiling swapped between sides | caught | tests: 3 failing, e.g. StaticOrderPolicyTest.test_A3_buyAtTheCeilingPassesAndAboveItDoesNot |
| policies | A4 hour off by one | caught | tests: 3 failing, e.g. StaticOrderPolicyTest.test_A4_aBlockedHourIsBlockedForItsSideOnly |
| policies | A4 blocked hours of the other side | caught | tests: 3 failing, e.g. StaticOrderPolicyTest.test_A4_aBlockedHourIsBlockedForItsSideOnly |
| policies | A6 a slot starting now is in horizon | caught | tests: 1 failing, e.g. StaticOrderPolicyTest.test_A6_theHorizonIsBoundedOnBothSides |
| policies | A6 horizon exclusive | caught | tests: 1 failing, e.g. StaticOrderPolicyTest.test_A6_theHorizonIsBoundedOnBothSides |
| policies | a cancel leg is checked as a placement | caught | tests: 3 failing, e.g. StaticOrderPolicyTest.test_A1_minimumQuantityIsBoundedInclusively |
| policies | a longer horizon is not a widening | caught | tests: 1 failing, e.g. StaticOrderPolicyTest.test_everyLooserParameterIsAWidening |
| policies | fewer blocked hours is not a widening | caught | tests: 1 failing, e.g. StaticOrderPolicyTest.test_everyLooserParameterIsAWidening |
| policies | S1 counts sales: net or gross confused | caught | tests: 2 failing, e.g. WindowPolicyTest.test_S1_isGross_aSaleNeitherCountsNorRefills |
| policies | S2 export counts purchases | caught | tests: 1 failing, e.g. WindowPolicyTest.test_S2_exportAndImportAreSeparateAndNeverNetted |
| policies | S1 counts Wh instead of value | caught | tests: 9 failing, e.g. WindowPolicyTest.test_S1_countsBuyValueFlagsAboveSoftAndRejectsAboveHard |
| policies | a cancel leg adds to the window | caught | tests: 3 failing, e.g. WindowPolicyTest.test_S1_creditForAPartlyFilledOrderNeverExceedsTheCharge |
| policies | no flag above the soft bound | caught | tests: 1 failing, e.g. WindowPolicyTest.test_S1_countsBuyValueFlagsAboveSoftAndRejectsAboveHard |
| policies | the commit adds nothing | caught | tests: 13 failing, e.g. WindowPolicyTest.test_S1_countsBuyValueFlagsAboveSoftAndRejectsAboveHard |
| policies | S1 credits the whole order, fills included | caught | tests: 1 failing, e.g. WindowPolicyTest.test_S1_creditForAPartlyFilledOrderNeverExceedsTheCharge |
| policies | a credit goes to the current bucket (spec 8, through the policy) | caught | tests: 3 failing, e.g. WindowPolicyTest.test_aCancellationIsCreditedBack |
| policies | a higher cap is not a widening | caught | tests: 1 failing, e.g. WindowPolicyTest.test_theDirectionTable |
| policies | a new bucket count is not a widening | caught | tests: 1 failing, e.g. WindowPolicyTest.test_theDirectionTable |
| policies | S above H accepted | caught | tests: 1 failing, e.g. WindowPolicyTest.test_theDirectionTable |
| policies | another quantity keeps the old count | caught | tests: 1 failing, e.g. WindowPolicyTest.test_countingAnotherQuantityStartsAfresh |
| policies | S6 cap exclusive | caught | tests: 2 failing, e.g. CancelQuotaPolicyTest.test_cancelledVolumeIsCappedInclusively |
| policies | the gate weight is ignored | caught | tests: 2 failing, e.g. CancelQuotaPolicyTest.test_aCancellationNearTheGateWeighsMore |
| policies | the gate window starts a second late | caught | tests: 1 failing, e.g. CancelQuotaPolicyTest.test_theGateWindowStartsExactlyAtItsLength |
| policies | the ratio is not enforced | caught | tests: 2 failing, e.g. CancelQuotaPolicyTest.test_cancellationsAreBoundedByWhatWasPlaced |
| policies | the free allowance is ignored | caught | tests: 2 failing, e.g. CancelQuotaPolicyTest.test_cancellationsAreBoundedByWhatWasPlaced |
| policies | messages are not counted | caught | tests: 1 failing, e.g. CancelQuotaPolicyTest.test_messagesAreCounted |
| policies | the message limit is off by one | caught | tests: 1 failing, e.g. CancelQuotaPolicyTest.test_messagesAreCounted |
| policies | placements are not counted | caught | tests: 4 failing, e.g. CancelQuotaPolicyTest.test_aCancellationNearTheGateWeighsMore |
| policies | cancellations are not counted | caught | tests: 4 failing, e.g. CancelQuotaPolicyTest.test_aCancellationNearTheGateWeighsMore |
| policies | expiry counted as cancel in S6 (spec 8) | caught | tests: 3 failing, e.g. CancelQuotaPolicyTest.test_aCancellationNearTheGateWeighsMore |
| policies | a lower gate weight is not a widening | caught | tests: 1 failing, e.g. CancelQuotaPolicyTest.test_theDirectionTable |
| physical | reading accepted with a decreasing timestamp (spec 8) | caught | tests: 4 failing, e.g. GateReadingsTest.test_aReorderedReadingStopsTheSubmission |
| physical | a stale reading accepted | caught | tests: 2 failing, e.g. GateReadingsTest.test_aStaleReadingStopsTheSubmission |
| physical | the maximum age exclusive | caught | tests |
| physical | a reading from the future accepted | caught | tests |
| physical | any signer accepted | caught | tests: 9 failing, e.g. GateReadingsTest.test_aForgedReadingStopsTheSubmission |
| physical | the high-s twin accepted | caught | tests: 1 failing, e.g. OracleVerifierTest.test_theHighSTwinOfAValidSignatureIsRefused |
| physical | a conflicting reading with the same timestamp accepted | caught | tests: 1 failing, e.g. OracleVerifierTest.test_aDifferentReadingWithTheSameTimestampIsRefused |
| physical | the odometer may go down | caught | tests: 1 failing, e.g. OracleVerifierTest.test_theOdometerCannotGoDown |
| physical | a new signer keeps the old device's reading | caught | tests: 1 failing, e.g. OracleVerifierTest.test_aNewSignerDropsTheOldDevicesReading |
| physical | a stored reading never goes stale | caught | tests: 5 failing, e.g. GateReadingsTest.test_aReadingHandedInEarlierServesLaterOrdersWhileFresh |
| physical | a forecast served between its slots | caught | tests: 1 failing, e.g. OracleVerifierTest.test_aForecastIsServedSlotBySlot |
| physical | a stale forecast served to the policies | caught | tests: 1 failing, e.g. DeliverabilityPolicyTest.test_aStaleForecastGivesNoCredit |
| physical | a forecast of any length | caught | tests: 1 failing, e.g. OracleVerifierTest.test_aMalformedForecastIsRefused |
| physical | the domain does not bind the chain | caught | tests: 56 failing, e.g. GateReadingsTest.test_aForgedReadingStopsTheSubmission |
| physical | a reading for another account accepted | caught | tests: 2 failing, e.g. GateReadingsTest.test_aGridStateCannotComeWithAnOrder |
| physical | any number of readings | caught | tests: 1 failing, e.g. GateReadingsTest.test_atMostFourReadingsPerSubmission |
| physical | the verifier allowed as target | caught | tests: 3 failing, e.g. GateReadingsTest.test_noDecoderCanBeApprovedForTheVerifierNorCanItBeTargeted |
| physical | the ledger's batch view off by one slot | caught | tests: 8 failing, e.g. RampPolicyTest.test_aModificationThatSpreadsTheSpikePasses |
| physical | the horizon starts a slot late | caught | tests: 6 failing, e.g. CyclePolicyTest.test_aSaleBeyondTheHorizonIsRefused |
| physical | placed buys credited in the S3 floor (spec 8) | caught | tests: 3 failing, e.g. DeliverabilityPolicyTest.test_aBidPassesWhileTheFloorIsShort |
| physical | S3 accepts a placement outside its horizon (spec 8: H_slots <= k) | caught | tests: 1 failing, e.g. DeliverabilityPolicyTest.test_aSlotBeyondTheHorizonIsRefused |
| physical | S3 without a fresh reading | caught | tests: 2 failing, e.g. DeliverabilityPolicyTest.test_aReadingGoneStaleNoLongerServes |
| physical | S3 floor losses rounded down | caught | tests: 4 failing, e.g. DeliverabilityPolicyTest.test_C3_aLaterReserveRejectsASaleAFlatFloorAllows |
| physical | S3 shortfall not counted | caught | tests: 15 failing, e.g. DeliverabilityPolicyTest.test_C3_aFractionalFloorRoundsUp |
| physical | S3 floor hour off by one | caught | tests: 1 failing, e.g. DeliverabilityPolicyTest.test_C3_aSlotTakesTheFloorOfTheHourItStartsIn |
| physical | S3 floor of the first slot's hour throughout | caught | tests: 2 failing, e.g. DeliverabilityPolicyTest.test_C3_aLaterReserveRejectsASaleAFlatFloorAllows |
| physical | S3 a floor lowered in one hour is not a widening | caught | tests: 1 failing, e.g. DeliverabilityPolicyTest.test_whatLoosensWidensAndWhatTightensTightens |
| physical | S3 a floor above the ceiling in one hour is valid | caught | tests: 1 failing, e.g. DeliverabilityPolicyTest.test_malformedConfigurationsAreInvalid |
| physical | S3 profile floor rounded down | caught | tests: 1 failing, e.g. DeliverabilityPolicyTest.test_C3_aFractionalFloorRoundsUp |
| physical | S3 ceiling excess not counted | caught | tests: 1 failing, e.g. DeliverabilityPolicyTest.test_bidsThatWouldOverfillTheBatteryAreBlocked |
| physical | S3 discharge power not checked | caught | tests: 2 failing, e.g. DeliverabilityPolicyTest.test_aSaleBeyondTheDischargePowerIsBlocked |
| physical | S3 charge power not checked | caught | tests: 1 failing, e.g. DeliverabilityPolicyTest.test_aBidBeyondTheChargePowerIsBlocked |
| physical | S3 PV above a full battery stored | caught | tests: 1 failing, e.g. DeliverabilityPolicyTest.test_PVBeyondAFullBatteryIsSpilled |
| physical | S3 rejects any shortfall, reduced or not | caught | tests: 2 failing, e.g. DeliverabilityPolicyTest.test_aBidPassesWhileTheFloorIsShort |
| physical | S3 counts a cancellation as a placement | caught | tests: 1 failing, e.g. DeliverabilityPolicyTest.test_aSmallerModificationPassesEvenShort |
| physical | S4 discharge never added to the window | caught | tests: 5 failing, e.g. CyclePolicyTest.test_excessCyclingIsBlocked |
| physical | S4 ignores the odometer beyond the window | caught | tests: 1 failing, e.g. CyclePolicyTest.test_excessCyclingIsBlocked |
| physical | S4 pending without the efficiency | caught | tests: 3 failing, e.g. CyclePolicyTest.test_aSaleWithinTheBudgetPasses |
| physical | S4 pending without the PV credit | caught | tests: 1 failing, e.g. CyclePolicyTest.test_thePVCreditNetsThePending |
| physical | S4 judges a sale without a fresh reading | caught | tests: 1 failing, e.g. CyclePolicyTest.test_aSaleAfterTheReadingWentStaleIsRefused |
| physical | S4 judges a bid as a sale | caught | tests: 1 failing, e.g. CyclePolicyTest.test_aBidIsNeverJudgedAndNeedsNoReading |
| physical | S4 cap exclusive | caught | tests: 1 failing, e.g. CyclePolicyTest.test_excessCyclingIsBlocked |
| physical | S4 rejects what does not add | caught | tests: 1 failing, e.g. CyclePolicyTest.test_aSmallerSalePassesOverTheCap |
| physical | S5 looks only to the left | caught | tests: 1 failing, e.g. RampPolicyTest.test_theStepToTheRightCountsToo |
| physical | S5 rejects steps it did not make larger | caught | tests: 1 failing, e.g. RampPolicyTest.test_aSmoothingOrderPassesWhileTheProfileIsTooSteep |
| physical | S5 rejects above the soft bound | caught | tests: 2 failing, e.g. RampPolicyTest.test_aBuySpikeIsBlockedToo |
| physical | S5 treats a cancellation as a placement | caught | tests: 2 failing, e.g. RampPolicyTest.test_aModificationThatSpreadsTheSpikePasses |
| oracle2 | a market registered without its grid checked | caught | tests: 5 failing, e.g. MultiMarketTest.test_aMarketShiftedByWholeSlotsIsRefused |
| oracle2 | a market without a grid registered | caught | tests: 1 failing, e.g. MultiMarketTest.test_aMarketWithoutASlotGridIsRefused |
| oracle2 | the grid checked on its length only | caught | tests: 2 failing, e.g. MultiMarketTest.test_aMarketShiftedByWholeSlotsIsRefused |
| oracle2 | the grid checked on its origin only | caught | tests: 2 failing, e.g. MultiMarketTest.test_aMarketWithAnotherSlotLengthIsRefused |
| oracle2 | a grid of zero length fixed | caught | tests: 1 failing, e.g. MultiMarketTest.test_aGridHasASlotLength |
| oracle2 | anyone fixes a grid | caught | tests |
| oracle2 | a meter or envelope signer may be the BMS signer | caught | tests: 3 failing, e.g. OracleVerifierV2Test.test_aBmsOrPvSignerMayBeNeitherTheMeterNorTheEnvelopeSigner |
| oracle2 | a meter or envelope signer may be the PV signer | caught | tests: 3 failing, e.g. OracleVerifierV2Test.test_aBmsOrPvSignerMayBeNeitherTheMeterNorTheEnvelopeSigner |
| oracle2 | distinctness in one registration order only | caught | tests: 1 failing, e.g. OracleVerifierV2Test.test_aBmsOrPvSignerMayBeNeitherTheMeterNorTheEnvelopeSigner |
| oracle2 | a signer may be a declared agent key | caught | tests: 1 failing, e.g. OracleVerifierV2Test.test_noSignerOfAnyKindMayBeADeclaredAgentKey |
| oracle2 | an agent key may be a registered signer | caught | tests: 1 failing, e.g. OracleVerifierV2Test.test_noAgentKeyMayBeARegisteredSigner |
| oracle2 | an agent key checked against the BMS signer only | caught | tests: 1 failing, e.g. OracleVerifierV2Test.test_noAgentKeyMayBeARegisteredSigner |
| oracle2 | one agent key more than the bound | caught | tests: 1 failing, e.g. OracleVerifierV2Test.test_agentKeysAreBoundedAndCanBeWithdrawn |
| oracle2 | a meter reading from any signer accepted | caught | tests: 1 failing, e.g. OracleVerifierV2Test.test_aMeterReadingFromAnotherSignerIsRefused |
| oracle2 | a meter reading for a slot not yet over accepted | caught | tests: 1 failing, e.g. OracleVerifierV2Test.test_aMeterReadingForASlotNotYetOverIsRefused |
| oracle2 | a meter reading refused for the slot that just ended | caught | tests |
| oracle2 | a meter reading older than the ring accepted | caught | tests: 1 failing, e.g. OracleVerifierV2Test.test_aMeterReadingOlderThanTheRingIsStale |
| oracle2 | a conflicting meter reading accepted | caught | tests: 1 failing, e.g. OracleVerifierV2Test.test_aConflictingMeterReadingIsRefusedAndTheSameIsANoOp |
| oracle2 | a meter reading off the slot grid accepted | caught | tests |
| oracle2 | the meter ring indexed one slot late | caught | tests: 5 failing, e.g. OracleVerifierV2Test.test_aConflictingMeterReadingIsRefusedAndTheSameIsANoOp |
| oracle2 | the meter view ignores the slot it holds | caught | tests: 1 failing, e.g. OracleVerifierV2Test.test_theRingEvictsTheSlotOneRingBack |
| oracle2 | a new meter keeps the old meter's readings | caught | tests: 1 failing, e.g. OracleVerifierV2Test.test_aNewMeterDropsTheReadingsHeld |
| oracle2 | a schedule with series of different lengths accepted | caught | tests: 2 failing, e.g. OracleVerifierV2Test.test_aMalformedOrStaleEnvelopeIsRefused |
| oracle2 | a schedule of any length accepted | caught | tests: 1 failing, e.g. OracleVerifierV2Test.test_aMalformedTariffIsRefused |
| oracle2 | a stale schedule served | caught | tests: 1 failing, e.g. OracleVerifierV2Test.test_aTariffGoesStaleAfterItsMaximumAge |
| oracle2 | a schedule served between its slots | caught | tests: 1 failing, e.g. OracleVerifierV2Test.test_aTariffServesOnlyTheSlotsItCovers |
| oracle2 | a new tariff signer keeps the old tariff | caught | tests: 1 failing, e.g. OracleVerifierV2Test.test_aNewSignerDropsTheScheduleHeld |
| oracle2 | a new envelope signer keeps the old envelope | caught | tests: 1 failing, e.g. OracleVerifierV2Test.test_aNewSignerDropsTheScheduleHeld |
| oracle2 | an expired grid state accepted | caught | tests: 1 failing, e.g. OracleVerifierV2Test.test_aBadFutureExpiredReorderedOrConflictingGridStateIsRefused |
| oracle2 | a grid state from the future accepted | caught | tests: 1 failing, e.g. OracleVerifierV2Test.test_aBadFutureExpiredReorderedOrConflictingGridStateIsRefused |
| oracle2 | a reordered grid state accepted | caught | tests: 1 failing, e.g. OracleVerifierV2Test.test_aBadFutureExpiredReorderedOrConflictingGridStateIsRefused |
| oracle2 | a conflicting grid state accepted | caught | tests: 1 failing, e.g. OracleVerifierV2Test.test_aBadFutureExpiredReorderedOrConflictingGridStateIsRefused |
| oracle2 | a grid state no longer holds at validUntil | caught | tests: 2 failing, e.g. OracleVerifierV2Test.test_aGridStateFromTheRegisteredOperatorHoldsUntilValidUntil |
| oracle2 | the grid state may take a maximum age | caught | tests: 1 failing, e.g. OracleVerifierV2Test.test_theGridStateTakesNoMaximumAge |
| breaker | G1 reject cap exclusive | caught | tests: 2 failing, e.g. SessionBreakerTest.test_ownerReinstatementClearsTheWindows |
| breaker | G1 flag cap exclusive | caught | tests: 2 failing, e.g. SessionBreakerTest.test_onOffAgent_isSuspendedWithinTheFlagWindow |
| breaker | G1 rejections not counted | caught | tests: 10 failing, e.g. RecipientLockTest.test_aRefusedMoveCountsTowardG1 |
| breaker | G1 flags not counted | caught | tests: 1 failing, e.g. SessionBreakerTest.test_onOffAgent_isSuspendedWithinTheFlagWindow |
| breaker | G1 counts while suspended | caught | tests: 1 failing, e.g. SessionBreakerTest.test_whileSuspended_thePoliciesStillJudgeACancellation |
| breaker | G1 counts while off | caught | tests: 12 failing, e.g. RecipientLockTest.test_aTokenTransferToTheAgentIsRefused |
| breaker | G1 a suspended account passes everything | caught | tests: 4 failing, e.g. RecipientLockTest.test_aRefusedMoveCountsTowardG1 |
| breaker | G1 a suspended account passes nothing | caught | tests: 2 failing, e.g. SessionBreakerTest.test_whileSuspended_aCancellationPasses |
| breaker | G1 cooldown boundary exclusive | caught | tests: 1 failing, e.g. SessionBreakerTest.test_autoReinstatementAfterTheCooldown |
| breaker | G1 no cooldown reinstates at once | caught | tests: 6 failing, e.g. RecipientLockTest.test_aRefusedMoveCountsTowardG1 |
| breaker | G1 owner reinstatement keeps the windows | caught | tests: 1 failing, e.g. SessionBreakerTest.test_ownerReinstatementClearsTheWindows |
| breaker | G1 only the gate records: check removed | caught | tests: 1 failing, e.g. SessionBreakerTest.test_onlyTheGateWritesTheBreaker |
| breaker | G1 a higher cap is not a widening | caught | tests: 2 failing, e.g. SessionBreakerTest.test_aWideningAppliesAfterTheTimelockOnly |
| breaker | G1 another window shape is not a widening | caught | tests: 1 failing, e.g. SessionBreakerTest.test_everyLooseningWaits |
| breaker | G1 a cooldown where there was none is not a widening | caught | tests: 1 failing, e.g. SessionBreakerTest.test_everyTighteningAppliesAtOnce |
| breaker | G1 turning off is not a widening | caught | tests: 1 failing, e.g. SessionBreakerTest.test_everyLooseningWaits |
| breaker | G1 a widening applies at once | caught | tests: 3 failing, e.g. SessionBreakerTest.test_aWideningAppliesAfterTheTimelockOnly |
| breaker | G1 the timelock not checked | caught | tests: 1 failing, e.g. SessionBreakerTest.test_aWideningAppliesAfterTheTimelockOnly |
| breaker | G1 a later write keeps the queued widening | caught | tests: 1 failing, e.g. SessionBreakerTest.test_aLaterWriteDropsAQueuedWidening |
| breaker | G1 a window of any class | caught | tests: 1 failing, e.g. SessionBreakerTest.test_aMalformedConfigurationIsRefused |
| breaker | G1 any cooldown | caught | tests: 1 failing, e.g. SessionBreakerTest.test_aMalformedConfigurationIsRefused |
| breaker | G1 never asked before the policies | caught | tests: 4 failing, e.g. RecipientLockTest.test_aRefusedMoveCountsTowardG1 |
| breaker | G1 a suspended refusal goes on to the market | caught | tests: 4 failing, e.g. RecipientLockTest.test_aRefusedMoveCountsTowardG1 |
| breaker | G1 a modification counts as cancel-only | caught | tests: 1 failing, e.g. SessionBreakerTest.test_whileSuspended_placementsAndModificationsAreRefused |
| breaker | G1 a funds move counts as cancel-only | caught | tests: 1 failing, e.g. RecipientLockTest.test_aRefusedMoveCountsTowardG1 |
| breaker | G1 rejections not recorded | caught | tests: 9 failing, e.g. SessionBreakerTest.test_aReinstallClearsTheBreaker |
| breaker | G1 flags not recorded | caught | tests: 1 failing, e.g. SessionBreakerTest.test_onOffAgent_isSuspendedWithinTheFlagWindow |
| breaker | G1 the breaker allowed as target | caught | tests: 1 failing, e.g. SessionBreakerTest.test_theAgentCannotReachTheBreaker |
| breaker | A9 any recipient accepted | caught | tests: 4 failing, e.g. RecipientLockTest.test_aRefusedMoveCountsTowardG1 |
| breaker | A9 any non-zero recipient accepted | caught | tests: 4 failing, e.g. RecipientLockTest.test_aRefusedMoveCountsTowardG1 |
| breaker | A9 any spender accepted | caught | tests: 3 failing, e.g. RecipientLockTest.test_anAllowanceForAnyoneElseIsRefused |
| breaker | A9 a refused move not counted by G1 | caught | tests: 1 failing, e.g. RecipientLockTest.test_aRefusedMoveCountsTowardG1 |
| breaker | A9 a refused move made anyway | caught | tests: 6 failing, e.g. RecipientLockTest.test_aTokenTransferToTheAgentIsRefused |
| breaker | A9 a funds move takes the order path | caught | tests: 8 failing, e.g. RecipientLockTest.test_aRefusedMoveCountsTowardG1 |
| breaker | A9 an UNKNOWN call registered | caught | tests: 1 failing, e.g. RecipientLockTest.test_aCallTheDecoderDoesNotKnowCannotBeRegistered |
| breaker | A9 an OPAQUE funds move registered | caught | tests: 1 failing, e.g. RecipientLockTest.test_aFundsMoveWithoutADecodableRecipientCannotBeRegistered |
| breaker | A9 a market's order calls not counted | caught | tests: 6 failing, e.g. RecipientLockTest.test_aMarketIsCountedByCallNotByRegistration |
| breaker | A9 a re-registered order call counted twice | caught | tests: 1 failing, e.g. RecipientLockTest.test_aMarketIsCountedByCallNotByRegistration |
| breaker | A9 removeDecoder keeps the market | caught | tests: 2 failing, e.g. RecipientLockTest.test_aMarketIsCountedByCallNotByRegistration |
| breaker | A9 a market needs two order calls | caught | tests: 2 failing, e.g. RecipientLockTest.test_aMarketIsCountedByCallNotByRegistration |
| breaker | A9 a token held to a slot grid | caught | tests: 1 failing, e.g. RecipientLockTest.setUp |
| breaker | A9 lock is a plain funds move | caught | tests: 1 failing, e.g. RecipientLockTest.test_aFundsMoveWithoutADecodableRecipientCannotBeRegistered |
| breaker | A9 unlock without a recipient pays no one | caught | tests: 1 failing, e.g. RecipientLockTest.test_theTokenDecoderExposesEveryRecipient |
| breaker | A9 the token's other calls are approvals | caught | tests: 1 failing, e.g. RecipientLockTest.test_aCallTheDecoderDoesNotKnowCannotBeRegistered |
| breaker | A9 the prosumer contract's other calls are orders | caught | tests: 1 failing, e.g. GatedMarketTest.test_A9_onlyTheOrderFunctionsCanBeRegistered |
| price | A3T BUY bound exclusive | caught | tests: 3 failing, e.g. TariffBandTest.test_aBuyMayGoUpToTheBandAboveRetail |
| price | A3T SELL bound exclusive | caught | tests: 3 failing, e.g. TariffBandTest.test_aSellMayGoDownToTheBandBelowFeedIn |
| price | A3T BUY bound rounded up | caught | tests: 1 failing, e.g. TariffBandTest.test_eachBoundRoundsTowardTheStricterSide |
| price | A3T SELL bound rounded down | caught | tests: 1 failing, e.g. TariffBandTest.test_eachBoundRoundsTowardTheStricterSide |
| price | A3T the BUY side takes the SELL beta | caught | tests: 1 failing, e.g. TariffBandTest.test_eachSideHasItsOwnBeta |
| price | A3T the SELL discount ignored | caught | tests: 5 failing, e.g. TariffBandTest.test_aSellMayGoDownToTheBandBelowFeedIn |
| price | A3T a SELL measured against retail | caught | tests: 4 failing, e.g. TariffBandTest.test_aSellMayGoDownToTheBandBelowFeedIn |
| price | A3T judges without a tariff | caught | tests: 3 failing, e.g. TariffBandTest.test_aSlotBeyondTheScheduleIsRefused |
| price | A3T applies when off | caught | tests: 16 failing, e.g. TariffBandTest.test_priceWalk_passesUnderA3Alone |
| price | A3T never applies | caught | tests: 8 failing, e.g. TariffBandTest.test_aBuyMayGoUpToTheBandAboveRetail |
| price | A3T the band off is not a widening | caught | tests: 2 failing, e.g. TariffBandTest.test_configurationDirections |
| price | A3T a higher markup is not a widening | caught | tests: 1 failing, e.g. TariffBandTest.test_configurationDirections |
| price | A3T a higher discount is not a widening | caught | tests: 1 failing, e.g. TariffBandTest.test_configurationDirections |
| price | A3T a 100 % discount is invalid | caught | tests: 1 failing, e.g. TariffBandTest.test_configurationDirections |
| price | S7 a BUY counted below retail | caught | tests: 8 failing, e.g. DominatedTradePolicyTest.test_aBuyAboveRetailCountsTheExcess |
| price | S7 a SELL counted above feed-in | caught | tests: 4 failing, e.g. DominatedTradePolicyTest.test_aSellBelowFeedInCountsTheShortfall |
| price | S7 a SELL measured against retail | caught | tests: 4 failing, e.g. DominatedTradePolicyTest.test_aSellBelowFeedInCountsTheShortfall |
| price | S7 the amount rounded down | caught | tests: 1 failing, e.g. DominatedTradePolicyTest.test_theAmountRoundsUp |
| price | S7 judges without a tariff | caught | tests: 1 failing, e.g. DominatedTradePolicyTest.test_withoutAUsableTariffAPlacementIsRefused |
| price | S7 flags at the soft bound | caught | tests: 1 failing, e.g. DominatedTradePolicyTest.test_atTheSoftBoundIsNotFlagged |
| price | S7 never flags | caught | tests: 1 failing, e.g. DominatedTradePolicyTest.test_aboveTheSoftBoundIsFlagged |
| price | S7 never rejects | caught | tests: 2 failing, e.g. DominatedTradePolicyTest.test_collusiveTransfer_isBlockedByS7 |
| price | S7 nothing added to the window | caught | tests: 8 failing, e.g. DominatedTradePolicyTest.test_aBuyAboveRetailCountsTheExcess |
| price | S7 the excess not kept | caught | tests: 6 failing, e.g. DominatedTradePolicyTest.test_aCancellationGivesItBack |
| price | S7 the credit looks under the wrong key | caught | tests: 3 failing, e.g. DominatedTradePolicyTest.test_aNewTariffDoesNotChangeTheCredit |
| price | S7 the filled part given back too | caught | tests: 1 failing, e.g. DominatedTradePolicyTest.test_onlyTheUnfilledPartIsGivenBack |
| price | S7 the credit to the current bucket | caught | tests: 2 failing, e.g. DominatedTradePolicyTest.test_anExpiryGivesItBack |
| price | S7 the key ignores the price | caught | tests: 1 failing, e.g. DominatedTradePolicyTest.test_ordersInOneBlockKeepTheirOwnExcess |
| price | S7 a higher cap is not a widening | caught | tests: 1 failing, e.g. DominatedTradePolicyTest.test_configurationDirections |
| price | S7 a soft bound above the cap is valid | caught | tests: 1 failing, e.g. DominatedTradePolicyTest.test_configurationDirections |
| roundtrip | S8 max for min, before | caught | tests: 9 failing, e.g. RoundTripPolicyTest.test_aModificationCountsOnlyWhatItAdds |
| roundtrip | S8 max for min, after | caught | tests: 10 failing, e.g. RoundTripPolicyTest.test_aModificationCountsOnlyWhatItAdds |
| roundtrip | S8 before and after swapped | caught | tests: 9 failing, e.g. RoundTripPolicyTest.test_aModificationCountsOnlyWhatItAdds |
| roundtrip | S8 a decrease counted too | caught | tests: 4 failing, e.g. RoundTripPolicyTest.test_aModificationCountsOnlyWhatItAdds |
| roundtrip | S8 the whole position counted, not the change | caught | tests: 4 failing, e.g. RoundTripPolicyTest.test_aModificationCountsOnlyWhatItAdds |
| roundtrip | S8 CANCEL legs not subtracted | caught | tests: 1 failing, e.g. RoundTripPolicyTest.test_aModificationCountsOnlyWhatItAdds |
| roundtrip | S8 CANCEL legs added | caught | tests: 2 failing, e.g. RoundTripPolicyTest.test_aModificationCountsOnlyWhatItAdds |
| roundtrip | S8 every leg on the buy side | caught | tests: 9 failing, e.g. RoundTripPolicyTest.test_aModificationCountsOnlyWhatItAdds |
| roundtrip | S8 the legs on one slot not merged | caught | tests: 1 failing, e.g. RoundTripPolicyTest.test_aModificationCountsOnlyWhatItAdds |
| roundtrip | S8 the first slot skipped | caught | tests: 9 failing, e.g. RoundTripPolicyTest.test_aModificationCountsOnlyWhatItAdds |
| roundtrip | S8 flags at the soft bound | caught | tests: 1 failing, e.g. RoundTripPolicyTest.test_atTheSoftBoundIsNotFlagged |
| roundtrip | S8 never flags | caught | tests: 1 failing, e.g. RoundTripPolicyTest.test_aboveTheSoftBoundIsFlagged |
| roundtrip | S8 never rejects | caught | tests: 2 failing, e.g. RoundTripPolicyTest.test_churnAcrossTwoMarkets_isStoppedByS8 |
| roundtrip | S8 a reduction judged too | caught | tests: 1 failing, e.g. RoundTripPolicyTest.test_whatAddsNothingAlwaysPasses |
| roundtrip | S8 nothing added to the window | caught | tests: 8 failing, e.g. RoundTripPolicyTest.test_aModificationCountsOnlyWhatItAdds |
| roundtrip | S8 a credit given back | caught | tests: 3 failing, e.g. RoundTripPolicyTest.test_aModificationCountsOnlyWhatItAdds |
| roundtrip | S8 a higher cap is not a widening | caught | tests: 1 failing, e.g. RoundTripPolicyTest.test_configurationDirections |
| roundtrip | S8 a higher soft bound is not a widening | caught | tests: 1 failing, e.g. RoundTripPolicyTest.test_configurationDirections |
| roundtrip | S8 another shape is not a widening | caught | tests: 1 failing, e.g. RoundTripPolicyTest.test_configurationDirections |
| roundtrip | S8 a soft bound above the cap is valid | caught | tests: 1 failing, e.g. RoundTripPolicyTest.test_configurationDirections |
| delivery | S9 alarm at h, not above | caught | tests: 1 failing, e.g. DeliveryReconciliationPolicyTest.test_level1IsInclusiveAtH_pen |
| delivery | S9 the slack k not taken off | caught | tests: 6 failing, e.g. DeliveryReconciliationPolicyTest.test_aShortfallCountsIntoTheCusum |
| delivery | S9 a net import counts beyond the sale | caught | tests: 1 failing, e.g. DeliveryReconciliationPolicyTest.test_theShortfallIsAtMostTheSale |
| delivery | S9 over-delivery counts as a shortfall | caught | tests: 1 failing, e.g. DeliveryReconciliationPolicyTest.test_deliveringInFullLetsTheCusumFall |
| delivery | S9 contracted export not net of buys | caught | tests: 1 failing, e.g. DeliveryReconciliationPolicyTest.test_contractedExportIsNetOfBuys |
| delivery | S9 C not reset on an alarm | caught | tests: 3 failing, e.g. DeliveryReconciliationPolicyTest.test_anAlarmStartsLevel1 |
| delivery | S9 settles at the slot's end, no lag | caught | tests: 10 failing, e.g. DeliveryReconciliationPolicyTest.test_aMissingReadingStopsSellingAfterGrace |
| delivery | S9 an unreconciled slot taken in | caught | tests: 1 failing, e.g. DeliveryReconciliationPolicyTest.test_anUnreconciledSlotWaits |
| delivery | S9 a sale without a reading taken in | caught | tests: 3 failing, e.g. DeliveryReconciliationPolicyTest.test_aMeterOffTheGridCountsAsMissing |
| delivery | S9 maxProcess off by one | caught | tests: 23 failing, e.g. ChronicOversellTest.test_chronicOversell_isStoppedByS9 |
| delivery | S9 a new instance starts at the slot in progress | caught | tests: 1 failing, e.g. DeliveryReconciliationPolicyTest.test_aNewInstanceStartsAtTheNextSlot |
| delivery | S9 blocks without waiting for grace | caught | tests: 1 failing, e.g. DeliveryReconciliationPolicyTest.test_aMissingReadingStopsSellingAfterGrace |
| delivery | S9 grace exclusive | caught | tests: 3 failing, e.g. DeliveryReconciliationPolicyTest.test_aMeterOffTheGridCountsAsMissing |
| delivery | S9 never blocks | caught | tests: 3 failing, e.g. DeliveryReconciliationPolicyTest.test_aMeterOffTheGridCountsAsMissing |
| delivery | S9 blocks buys too | caught | tests: 2 failing, e.g. DeliveryReconciliationPolicyTest.test_aMissingReadingStopsSellingAfterGrace |
| delivery | S9 counts a cancellation as a sale | caught | tests: 3 failing, e.g. DeliveryReconciliationPolicyTest.test_aMissingReadingStopsSellingAfterGrace |
| delivery | S9 level 2 never rejects | caught | tests: 2 failing, e.g. DeliveryReconciliationPolicyTest.test_aRejectedSubmissionPersistsNothing |
| delivery | S9 level 1 never judged | caught | tests: 3 failing, e.g. ChronicOversellTest.test_chronicOversell_isStoppedByS9 |
| delivery | S9 H_pen exclusive | caught | tests: 1 failing, e.g. DeliveryReconciliationPolicyTest.test_level1IsInclusiveAtH_pen |
| delivery | S9 the penalty never ends | caught | tests: 1 failing, e.g. DeliveryReconciliationPolicyTest.test_thePenaltyEnds |
| delivery | S9 the penalty's end inclusive | caught | tests: 1 failing, e.g. DeliveryReconciliationPolicyTest.test_thePenaltyEnds |
| delivery | S9 a second alarm stays at level 1 | caught | tests: 2 failing, e.g. DeliveryReconciliationPolicyTest.test_aRejectedSubmissionPersistsNothing |
| delivery | S9 the first alarm is level 2 | caught | tests: 8 failing, e.g. ChronicOversellTest.test_chronicOversell_isStoppedByS9 |
| delivery | S9 the level never decays | caught | tests: 1 failing, e.g. DeliveryReconciliationPolicyTest.test_theLevelDecays |
| delivery | S9 commit does not count sells | caught | tests: 3 failing, e.g. ChronicOversellTest.test_chronicOversell_isStoppedByS9 |
| delivery | S9 no credit for a released sale | caught | tests: 1 failing, e.g. DeliveryReconciliationPolicyTest.test_level1IsInclusiveAtH_pen |
| delivery | S9 commit persists nothing | caught | tests: 2 failing, e.g. DeliveryReconciliationPolicyTest.test_gas_processing |
| delivery | S9 poke persists nothing | caught | tests: 24 failing, e.g. ChronicOversellTest.test_chronicOversell_isStoppedByS9 |
| delivery | S9 reset keeps the level | caught | tests: 1 failing, e.g. DeliveryReconciliationPolicyTest.test_theOwnerResets |
| delivery | S9 reset keeps the pointer | caught | tests: 1 failing, e.g. DeliveryReconciliationPolicyTest.test_theOwnerResets |
| delivery | gate poke without an installed instance | caught | tests: 1 failing, e.g. DeliveryReconciliationPolicyTest.test_pokeNeedsAnInstalledInstance |
| delivery | gate resetPolicy by anyone | caught | tests: 1 failing, e.g. DeliveryReconciliationPolicyTest.test_onlyAnAccountResets |
| delivery | S9 a higher k is not a widening | caught | tests: 1 failing, e.g. DeliveryReconciliationPolicyTest.test_configurationDirections |
| delivery | S9 a shorter penalty is not a widening | caught | tests: 1 failing, e.g. DeliveryReconciliationPolicyTest.test_configurationDirections |
| delivery | S9 a longer grace is not a widening | caught | tests: 1 failing, e.g. DeliveryReconciliationPolicyTest.test_configurationDirections |
| delivery | S9 a higher H_pen is not a widening | caught | tests: 1 failing, e.g. DeliveryReconciliationPolicyTest.test_configurationDirections |
| delivery | S9 no processing is valid | caught | tests: 1 failing, e.g. DeliveryReconciliationPolicyTest.test_configurationDirections |
| envelope | S10 an equal excess is a worsening | caught | tests: 11 failing, e.g. OperatingEnvelopePolicyTest.test_aModificationIsJudgedAsOne |
| envelope | S10 never rejects | caught | tests: 8 failing, e.g. OperatingEnvelopePolicyTest.test_aStaleEnvelopeFallsBackToStatic |
| envelope | S10 flags at sigma | caught | tests: 1 failing, e.g. OperatingEnvelopePolicyTest.test_aboveSigmaIsFlagged |
| envelope | S10 flags a reduction | caught | tests: 1 failing, e.g. OperatingEnvelopePolicyTest.test_aTighteningUpdate |
| envelope | S10 never flags | caught | tests: 2 failing, e.g. OperatingEnvelopePolicyTest.test_aboveSigmaIsFlagged |
| envelope | S10 the envelope ignored | caught | tests: 7 failing, e.g. OperatingEnvelopePolicyTest.test_aStaleEnvelopeFallsBackToStatic |
| envelope | S10 the static limit not per slot | caught | tests: 2 failing, e.g. OperatingEnvelopePolicyTest.test_theStaticLimitHoldsForImportToo |
| envelope | S10 use against the other limit | caught | tests: 2 failing, e.g. OperatingEnvelopePolicyTest.test_aboveSigmaIsFlagged |
| envelope | S10 export excess against the import limit | caught | tests: 3 failing, e.g. OperatingEnvelopePolicyTest.test_aTighteningUpdate |
| envelope | S10 use rounded down | caught | tests: 1 failing, e.g. OperatingEnvelopePolicyTest.test_useRoundsUpAndAZeroLimitIsUnbounded |
| envelope | S10 a zero limit is no use | caught | tests: 1 failing, e.g. OperatingEnvelopePolicyTest.test_useRoundsUpAndAZeroLimitIsUnbounded |
| envelope | S10 the position gross, not net | caught | tests: 3 failing, e.g. OperatingEnvelopePolicyTest.test_theEnvelopesLimitsApplyEachWay |
| envelope | S10 CANCEL legs added | caught | tests: 2 failing, e.g. OperatingEnvelopePolicyTest.test_aModificationIsJudgedAsOne |
| envelope | S10 the legs of one slot not merged | caught | tests: 1 failing, e.g. OperatingEnvelopePolicyTest.test_aModificationIsJudgedAsOne |
| envelope | S10 the first slot not judged | caught | tests: 9 failing, e.g. OperatingEnvelopePolicyTest.test_aStaleEnvelopeFallsBackToStatic |
| envelope | S10 a higher P_conn is not a widening | caught | tests: 1 failing, e.g. OperatingEnvelopePolicyTest.test_configurationDirections |
| envelope | S10 a higher sigma is not a widening | caught | tests: 1 failing, e.g. OperatingEnvelopePolicyTest.test_configurationDirections |
| envelope | S10 sigma above 100 % is valid | caught | tests: 1 failing, e.g. OperatingEnvelopePolicyTest.test_configurationDirections |
| gridstate | A10 DEFICIT refuses an unchanged slot | caught | tests: 1 failing, e.g. GridStatePolicyTest.test_aPriceOnlyModificationPassesEitherWay |
| gridstate | A10 SURPLUS refuses an unchanged slot | caught | tests: 1 failing, e.g. GridStatePolicyTest.test_aPriceOnlyModificationPassesEitherWay |
| gridstate | A10 DEFICIT refuses what helps | caught | tests: 7 failing, e.g. GridStatePolicyTest.test_aMinimumLevelOfEmergencyIgnoresAlerts |
| gridstate | A10 EMERGENCY refuses cancellations | caught | tests: 1 failing, e.g. GridStatePolicyTest.test_emergencyWithNoDirectionRefusesEveryPlacement |
| gridstate | A10 ALERT with no direction refuses placements | caught | tests: 1 failing, e.g. GridStatePolicyTest.test_alertWithNoDirectionRefusesNothing |
| gridstate | A10 never refuses | caught | tests: 9 failing, e.g. GridStatePolicyTest.test_aMinimumLevelOfEmergencyIgnoresAlerts |
| gridstate | A10 a stale state still applies | caught | tests: 1 failing, e.g. GridStatePolicyTest.test_aStaleStateIsNormal |
| gridstate | A10 the minimum level exclusive | caught | tests: 7 failing, e.g. GridStatePolicyTest.test_aMinimumLevelOfEmergencyIgnoresAlerts |
| gridstate | A10 the horizon's end inclusive | caught | tests: 1 failing, e.g. GridStatePolicyTest.test_theHorizonEdge |
| gridstate | A10 the horizon ignored | caught | tests: 1 failing, e.g. GridStatePolicyTest.test_theHorizonEdge |
| gridstate | A10 the legs of one slot not merged | caught | tests: 2 failing, e.g. GridStatePolicyTest.test_aPriceOnlyModificationPassesEitherWay |
| gridstate | A10 CANCEL legs added | caught | tests: 3 failing, e.g. GridStatePolicyTest.test_counterGrid_isBlockedByA10 |
| gridstate | A10 the sides swapped | caught | tests: 8 failing, e.g. GridStatePolicyTest.test_aMinimumLevelOfEmergencyIgnoresAlerts |
| gridstate | A10 a higher minimum level is not a widening | caught | tests: 1 failing, e.g. GridStatePolicyTest.test_configurationDirections |
| gridstate | A10 any minimum level is valid | caught | tests: 1 failing, e.g. GridStatePolicyTest.test_configurationDirections |
| accounts | submit open to any caller | caught | tests: 4 failing, e.g. PolicyGateAccountsTest.test_kernel |
| accounts | unknown-call check removed | caught | tests: 2 failing, e.g. PolicyGateAccountsTest.test_nexus |
| accounts | account allowed as target everywhere | caught | tests: 4 failing, e.g. PolicyGateAccountsTest.test_kernel |
| accounts | gate allowed as target everywhere | caught | tests: 4 failing, e.g. PolicyGateAccountsTest.test_kernel |
| accounts | owner path open to anyone | caught | tests: 4 failing, e.g. PolicyGateAccountsTest.test_kernel |
| accounts | widening applies at once | caught | tests: 4 failing, e.g. PolicyGateAccountsTest.test_kernel |
| accounts | market call skipped | caught | tests |
| accounts | uninstall leaves installed | caught | tests: 4 failing, e.g. PolicyGateAccountsTest.test_kernel |
| accounts | executor claims to be a validator only | caught | tests |
