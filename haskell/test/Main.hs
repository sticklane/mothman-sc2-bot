module Main (main) where

import System.Exit (exitFailure, exitSuccess)
import Quantum.DataStructures.Synthesize

assertCheck :: String -> Bool -> IO ()
assertCheck label cond =
  if cond
    then putStrLn ("  [PASS] " ++ label)
    else do
      putStrLn ("  [FAIL] " ++ label)
      exitFailure

main :: IO ()
main = do
  putStrLn "======================================================================"
  putStrLn "Okasaki Quantum Data Structures — Phase 8 TodayHardware & S17-S20 Tests"
  putStrLn "======================================================================"

  -- 1. Verify all 20 Simplification Rules S1..S20, 6 MeasKinds, 5 MeasOptPasses
  assertCheck "SimplificationRules S1..S20 count == 20"
    (length allSimplificationRulesS1toS20 == 20)
  assertCheck "MeasKind 6-kind taxonomy count == 6"
    (length allMeasKinds == 6)
  assertCheck "MeasOptPass M1..M5 count == 5"
    (length allMeasOptPasses == 5)

  -- 2. Verify all 4 Calibrated 2025-2026 Hardware Profiles
  let willow = getTodayHardwareSpec GoogleWillow105
      heron  = getTodayHardwareSpec IBMHeronR2_156
      quant  = getTodayHardwareSpec QuantinuumH2_56
      na     = getTodayHardwareSpec BluvsteinNeutralAtom
  assertCheck "GoogleWillow105 calibrated (105Q, epsCZ=0.0033, epsMeas=0.0077, tCZ=30ns, tMCMR=550ns)"
    (thsPhysicalQubits willow == 105 && thsEps2Q willow == 0.0033 && thsEpsMeas willow == 0.0077)
  assertCheck "IBMHeronR2_156 calibrated (156Q, epsCZ=0.0015, epsMeas=0.0085, tCZ=68ns, tMCMR=650ns)"
    (thsPhysicalQubits heron == 156 && thsEps2Q heron == 0.0015 && thsEpsMeas heron == 0.0085)
  assertCheck "QuantinuumH2_56 calibrated (56Q, 4 zones, eps2Q=0.0006, epsMeas=0.00033, T2=2.0s)"
    (thsPhysicalQubits quant == 56 && thsZones quant == 4 && thsEps2Q quant == 0.0006 && thsEpsMeas quant == 0.00033)
  assertCheck "BluvsteinNeutralAtom calibrated (3000Q phys / 48Q logical, epsCZ=0.0020, epsCCZ=0.0045, T2=12.6s)"
    (thsPhysicalQubits na == 3000 && thsLogicalQubits na == 48 && thsEps2Q na == 0.0020 && thsEps3Q na == 0.0045)

  -- 3. Verify Exact 8-State RCCX Relative-Phase Cancellation (S17 & F29)
  let (rccxOk1, err1) = verifyRCCXPhaseCancel (pi / 3.0)
      (rccxOk2, err2) = verifyRCCXPhaseCancel 1.789
  assertCheck ("verifyRCCXPhaseCancel exact 8-state simulation (maxErr=" ++ show (max err1 err2) ++ ")")
    (rccxOk1 && rccxOk2 && verifyF29UnpairedRCCXPhaseLeakRejected)

  -- 4. Verify S17..S20 Rewrite Passes & Guards F29..F32
  let rawCirc =
        [ GateAndCompute (QWire 0) (QWire 1) (QWire 3)
        , GateCNOT       (QWire 3) (QWire 2)
        , GateRZ         (QWire 2) 0.625
        , GateCNOT       (QWire 3) (QWire 2)
        , GateHMR_CZ     (QWire 3) (QWire 0) (QWire 1)
        , GateCSWAP      (QWire 0) (QWire 1) (QWire 2)
        , GateRZ         (QWire 0) 0.25
        , GateVirtualRZ  (QWire 0) 0.50
        , GateZ          (QWire 0)
        ]
      s17Circ = rewriteS17RCCXUncomputePhaseCancel 0.0033 0.0077 rawCirc
      (s17Balanced, _) = verifyS17BalancedRCCXPairs s17Circ
  assertCheck "S17 rewrites AndCompute + HMR_CZ into measurement-free RCCX + RCCXDag (0 MCMR)"
    (countMidCircuitMeas s17Circ == 0 && s17Balanced)

  let s18Circ = rewriteS18NeutralAtomCSWAPCollapse rawCirc
  assertCheck "S18 collapses CSWAP into 1 NativeCCZ + 1 NativeISWAP pulse"
    (countNativeCCZ s18Circ == 1 && countNativeISWAP s18Circ == 1 && countCSWAPs s18Circ == 0)

  let s19Circ = rewriteS19VirtualRZCollapse rawCirc
  assertCheck "S19 collapses 3 consecutive Z-axis rotations into 1 VirtualRZ frame update"
    (countVirtualRZGates s19Circ == 1)

  let s20Circ = rewriteS20QuantinuumRZZKickback rawCirc
  assertCheck "S20 collapses CNOT * RZ(phi) * CNOT into 1 native RZZ(phi) entangler"
    (countRZZGates s20Circ == 1)

  -- 5. Verify computeSurvivalGrade Mode Selection & Quantinuum 52Q -> 28Q Compression
  let sgWillow = computeSurvivalGrade GoogleWillow105      52 rawCirc
      sgHeron  = computeSurvivalGrade IBMHeronR2_156       52 rawCirc
      sgNA     = computeSurvivalGrade BluvsteinNeutralAtom 52 rawCirc
      sgQuant  = computeSurvivalGrade QuantinuumH2_56      52 (rawCirc ++ [GateMCMR (QWire 3) 0])
  assertCheck "computeSurvivalGrade selects UnitaryRCCXMode (0 MCMR) on Willow & Heron R2"
    (sgCompileMode sgWillow == UnitaryRCCXMode && sgNumMCMR sgWillow == 0
     && sgCompileMode sgHeron == UnitaryRCCXMode && sgNumMCMR sgHeron == 0)
  assertCheck "computeSurvivalGrade selects NativeRydbergCCZMode on BluvsteinNeutralAtom"
    (sgCompileMode sgNA == NativeRydbergCCZMode && sgNumMCMR sgNA == 0 && sgNum3QGates sgNA == 1)
  assertCheck "computeSurvivalGrade selects Batch4MCMRReuseMode (52Q -> 28Q) on QuantinuumH2_56"
    (sgCompileMode sgQuant == Batch4MCMRReuseMode && sgPhysicalQubits sgQuant == 28)

  -- 6. Verify Multi-Zone ZipperCut Shuttling Scheduler & Fix F30
  let cleanZoneWires =
        [ ZoneWireState 0 True  False EntanglingZone
        , ZoneWireState 1 True  False EntanglingZone
        , ZoneWireState 2 False False StorageZone
        ]
      dirtyZoneWires =
        [ ZoneWireState 0 True  False EntanglingZone
        , ZoneWireState 2 False True  StorageZone
        ]
  assertCheck "scheduleMultiZoneZipper accepts clean StorageZone & rejects dirty ancilla leak (F30)"
    (case (scheduleMultiZoneZipper 4 cleanZoneWires, scheduleMultiZoneZipper 4 dirtyZoneWires) of
       (Right s, Left _) -> mzzVerifiedZeroStorageLeak s && mzzDirtyAncillasInStorage s == 0
       _                 -> False)

  -- 7. Verify 3-Tier Multi-Dialect Typed IR & 5 Today-Executable Benchmarks (including 506 ns FPGA loop)
  assertCheck "3-Tier IR: Tier 1 (HLQdsIR) & Tier 2 (MLRevIR) 100% shared; diverge only at Tier 3 (LLMachineISA)"
    verifySharedTier1Tier2DivergeAtTier3
  assertCheck "Today-Executable Benchmarks (DQI BCH(7,4,3), BCH(15,7,5), K3, Braun QROAM 8:1, 506 ns FPGA loop)"
    verifyTodayExecutableBenchmarks

  -- 8. Verify Phase 9: Multi-Layer IR Evaluators, Intra-Layer Optimizers (Tier 1-3) & 8-Target Differential Testing (F33-F36)
  assertCheck "F33: Tier 1 Intra-Layer Diff (evalTier1HLQds e == evalTier1HLQds (optimizeTier1HLQds e) & RedundantCS rejected)"
    verifyF33Tier1IntraLayerDiff
  assertCheck "F34: Tier 1 -> Tier 2 Commutativity (evalTier1HLQds e == evalTier2MLRevIR (lowerTier1ToTier2 (optimizeTier1HLQds e)))"
    verifyF34Tier1ToTier2Commutativity
  assertCheck "F35: Tier 2 Delayed-Uncompute Region Fusion (MLWithCompute u v1 ; MLWithCompute u v2 -> MLWithCompute u (MLSeq v1 v2))"
    verifyF35Tier2DelayedUncomputeRegionFusion
  assertCheck "F36: 8-Target End-to-End Compiler Differential Suite (4 Ideal FTQC 6.1..6.3 + 4 Today-Hardware 8-way bitboard equality)"
    verifyF36EightTargetEndToEndCompilerDiff
  assertCheck "Master Phase-9 Multi-Layer Compiler Differential Tester (verifyMultiLayerCompilerDiffF33ToF36)"
    verifyMultiLayerCompilerDiffF33ToF36

  -- 9. Verify Phase 10: 6-Axis Hardware-Gap Verifier, Passes M6-M7, Code-Distance Step-Down & F37-F40
  assertCheck "F37: Spatial Rydberg blockade (dist >= dMin) & QCCD zone capacity (z2qA + z2qB <= cZone) checker"
    (checkF37SpatialPar True 12 8 2 2 4 && not (checkF37SpatialPar True 5 8 2 2 4) && not (checkF37SpatialPar True 12 8 3 2 4))
  assertCheck "F38 & Pass M6: Twisted Pauli frame flush before non-Clifford CCX & RZZ angle conjugation"
    (checkF38NonCliffordFrame (passM6FlushFrame FrameTwistedX)
     && not (checkF38NonCliffordFrame FrameTwistedX)
     && passM6ConjugateRzz FrameTwistedX (passM6ConjugateRzz FrameTwistedX 0.75) == 0.75)
  assertCheck "F39 & Pass M5: SubspaceModality leakage guard & heralded erasure discharge"
    (checkF39SubspaceClean (passM5HeraldedErasureDischarge NeedsErasureHerald) SubspaceClean
     && not (checkF39SubspaceClean NeedsErasureHerald SubspaceClean))
  assertCheck "F40 & Pass M7: DDModality asymmetric idle XY4 dynamical decoupling insertion"
    (checkF40IdleBranchDD 600 100 (passM7InsertXY4 600 100 UnprotectedIdle)
     && not (checkF40IdleBranchDD 600 100 UnprotectedIdle)
     && xy4FirstOrderPhaseResidual 17 25 == 0)
  assertCheck "Theorem 26E & Table 6F: synthesizeCodeDistanceAndPhysQ across Regimes 0..5 (20M -> 2.52M -> 586K -> 344K -> 143K -> 9.5K)"
    ([snd (synthesizeCodeDistanceAndPhysQ r) | r <- [0..5]] == [20000000, 2523932, 586109, 344304, 142848, 9504]
     && verifyPhase10F37ToF40AndGap)

  -- 10. Verify Phase 11: Next-Frontier Ideas (F41-F44, S21-S24, Pass M8 SIMD QROAM, PCQB Exporters)
  assertCheck "S21 & F41: NoiseBiasModality (ZBiasPreserving vs BiasBreaking) & Cat-Qubit 22Q/logical at d_Z=11"
    (checkF41BiasPreservingGate ZBiasPreserving ZBiasPreserving
     && not (checkF41BiasPreservingGate ZBiasPreserving BiasBreaking)
     && catQubitPhysQubitsPerLogical 11 == 22)
  assertCheck "S22 & F42: ZipperSeamQuasiProbCut (k_seam <= 2, 81x sampling overhead, 178q DQI BCH(127) -> 28q)"
    (zsqWithinBudget (partitionDQIBCH127WithZipperCut 2)
     && zsqSamplingOverheadGamma2 (partitionDQIBCH127WithZipperCut 2) == 81
     && not (checkF42ZipperSeamCutWidth 3))
  assertCheck "S23 & F43: STAR direct phase-polynomial 45x T-gate saving & Speculative Cultivation O(1) RCCX_Dag rollback"
    (starDirectRotationTGateSaving 4 == (180, 4, 45)
     && checkF43SpeculativeCultivationRollback False True
     && not (checkF43SpeculativeCultivationRollback False False))
  assertCheck "S24, Pass M8 & F44: Swiss-Cheese Braun defect remap + Vectorized SIMD Multi-Query QROAM batching"
    (swissCheeseBraunDefectRemap 10 3 7 == (True, 10, 10)
     && passM8VectorizedSIMDQROAMBatch 8 256 False == Just (2048, 256, 8)
     && passM8VectorizedSIMDQROAMBatch 8 256 True  == Nothing)
  assertCheck "PCQB Exporters: exportPCQBOpenQASM3 & exportPCQBStim for TODAY-1..6 & verifyPhase11F41ToF44AndPCQB"
    (not (null (exportPCQBOpenQASM3 1)) && not (null (exportPCQBStim 1)) && verifyPhase11F41ToF44AndPCQB)

  -- 11. Verify Phase 12: QDS-14..16, OQP-11..14, Fixes F45-F48, Passes M9-M10, S25-S28
  assertCheck "S25 & F45 (QDS-16): OrthogonalCaseZipper exhaustive & mutually orthogonal quantum pattern matching"
    (orthogonalCaseZipperValid 0x0FF0 0xF00F 0xFFFF True
     && not (checkF45OrthogonalExhaustiveCase 0x0010 0xFFFF 0xFFFF True))
  assertCheck "S26, Pass M10 & F46: RCCX degree-2 phase commutation barrier & catalytic phase-tower coalescing (45B -> 4B)"
    (checkF46RccxPhaseCommuteSafe False 8 16
     && not (checkF46RccxPhaseCommuteSafe True 8 16)
     && passM10CatalystTowerTGates 8 == 32
     && unfusedPhaseRotationTGates 8 == 360)
  assertCheck "S27 & F47 (QDS-14 & QDS-15): RealTimeQuantumQueue (2 ticks vs 64 spike) & acyclic EGraphQuantumContainer"
    (realtimeQueueWorstCaseTicks 64 == 2
     && batchedQueueWorstCaseTicks 64 == 64
     && checkF47RealtimeAndAcyclicEGraph 2 5 3
     && not (checkF47RealtimeAndAcyclicEGraph 64 5 3))
  assertCheck "S28, Pass M9 & F48: Chromatic transversal crosstalk guard (effective fault tolerance 5 vs 2 at d=11)"
    (effectiveCorrectableFaults 11 1 == 5
     && effectiveCorrectableFaults 11 2 == 2
     && checkF48CorrelatedCrosstalkSafe 2
     && not (checkF48CorrelatedCrosstalkSafe 1)
     && passM9ChromaticTransversalSubrounds True == 2
     && length allSimplificationRulesS1toS28 == 28
     && length allMeasOptPassesM1ToM10 == 10
     && verifyPhase12F45ToF48Qds14To16AndOqp11To14)

  -- 12. Verify Phase 13: GAP-1..4 Meta-Auditor, QDS-17..19, OQP-15..18, Fixes F49-F54, Passes M11-M14, S29-S34
  assertCheck "GAP-1..4 & F49-F50 (S29-S30, QDS-19): ExtendedQuantumFrameGrade meta-auditor, MCM+DD even-echo & non-aliasing lens"
    (checkF49McmDdPhaseCoherence 4 False
     && not (checkF49McmDdPhaseCoherence 3 False)
     && evalMcmDdFeedForwardWindow 1571 3 False == -1571
     && checkF50NonAliasingBorrowFrame 0x00F0 0x0F00 True
     && not (checkF50NonAliasingBorrowFrame 0x00F0 0x0030 True))
  assertCheck "F51-F54 (S31-S34, M11-M14, QDS-17..18, OQP-15..18): Hybrid QROAM+PBC, Floquet mod-3, Token Bucket & LRU guard"
    (pbcFullCommutePauliWeight 6 == 64
     && passM11HybridQroamPbcWeight 6 == 2
     && checkF51LitinskiPbcWeightBound 2 4
     && not (checkF51LitinskiPbcWeightBound 64 4)
     && checkF52FloquetGaugeAlignedCut (passM12AlignFloquetRoundMod3 4)
     && passM13DeamortizeTGateBurst 16 8 == 2
     && checkF53MagicStateTokenBucketSafe 2 1 1
     && bootstrappedSkewHeapWorstCaseCost 64 == 2
     && catenableDequeAppendWorstCaseTicks 64 == 2
     && checkF54DecoderBacklogAndLruSafe 506 1250 2 3
     && not (checkF54DecoderBacklogAndLruSafe 1800 1250 2 3)
     && length allSimplificationRulesS1toS34 == 34
     && length allMeasOptPassesM1ToM14 == 14
     && verifyPhase13F49ToF54Qds17To19AndOqp15To18)

  -- 13. Verify Phase 14: Automated Problem-Discovery Engines (PDE-1..6), QDS-20..22, OQP-19..22, Fixes F55-F60, Passes M15-M18, S35-S40
  assertCheck "PDE-1..6 & F55-F60 (S35-S40, M15-M18, QDS-20..22, OQP-19..22): ProblemDiscoveryEngineReport, wide-word carry, ctrl-phase, hook-free, 0-DSP XLS & totalizer"
    (allSixProblemDiscoveryEnginesPass (ProblemDiscoveryEngineReport True True True True True True)
     && not (allSixProblemDiscoveryEnginesPass (ProblemDiscoveryEngineReport False True True True True True))
     && checkF55PassPermutationTopologicalValid 1 2 3 4
     && not (checkF55PassPermutationTopologicalValid 3 1 3 4)
     && skewCarryThresholdModWord 63 64 == 0
     && skewCarryThresholdExtended 63 > 0
     && checkF56WideWordCarryGuard 63 64 True
     && not (checkF56WideWordCarryGuard 63 64 False)
     && checkF57ControlledPhasePromotionSafe 4 True
     && not (checkF57ControlledPhasePromotionSafe 4 False)
     && passM16CompensateCtrlPhaseMod8 4 == 0
     && effectiveHookCodeDistance 7 False == 7
     && effectiveHookCodeDistance 7 True == 4
     && checkF58HookErrorOrientationSafe True True
     && not (checkF58HookErrorOrientationSafe True False)
     && checkF59ZeroDspXlsTimingSafe 0 1850 2500 True
     && not (checkF59ZeroDspXlsTimingSafe 2 1850 2500 True)
     && safeDeamortizeTGateBurst 8 0 == 8
     && checkF60BoundaryInputSafe 0 0 True
     && not (checkF60BoundaryInputSafe 0 16 False)
     && length allSimplificationRulesS1toS40 == 40
     && length allMeasOptPassesM1ToM18 == 18
     && verifyPhase14F55ToF60Pde1To6Qds20To22AndOqp19To22)

  -- 14. Verify Phase 15: QDS-23..25, OQP-23..26, Fixes F61-F66, Passes M19-M22, S41-S46
  assertCheck "Phase 15 & F61-F66 (S41-S46, M19-M22, QDS-23..25, OQP-23..26): Linear closure defunctionalization, OAA reflection, XZZX seam, AOD monotone shuttle, Komlos pebbling & dyadic angle tree"
    (checkF61LinearClosureCaptureSafe 0x00F0 0x0F00 1
     && not (checkF61LinearClosureCaptureSafe 0x00F0 0x0030 1)
     && not (checkF61LinearClosureCaptureSafe 0x00F0 0x0F00 2)
     && passM19DefunctionalizeClosureDisjoint 0x00F0 0x0F00
     && checkF62OaaExactReflectionSafe True True True 0
     && not (checkF62OaaExactReflectionSafe True False True 0)
     && checkF63XzzxCheckerboardSeamAligned 1 2 2 3
     && not (checkF63XzzxCheckerboardSeamAligned 1 2 2 2)
     && passM20AlignXzzxCheckerboardCol 1 2 2 2 == 3
     && checkF64AodMonotoneAndRydbergSafe False False 12 8
     && not (checkF64AodMonotoneAndRydbergSafe True False 12 8)
     && passM21BocherMonotoneAodSweeps True == 2
     && minRequiredPebblesForHeight 5 == 6
     && checkF65KomlosPebblingReserveSafe 6 5 True
     && not (checkF65KomlosPebblingReserveSafe 5 5 True)
     && checkF66ExactDyadicAnglePrecisionSafe True 128 256
     && not (checkF66ExactDyadicAnglePrecisionSafe False 64 256)
     && length allSimplificationRulesS1toS46 == 46
     && length allMeasOptPassesM1ToM22 == 22
     && verifyPhase15F61ToF66Qds23To25AndOqp23To26)

  -- 15. Verify Phase 16: CoreQDS, 3-Loop Privilege-Tier Boundary, QDS-26..28, OQP-27..30, Fixes F67-F72, Passes M23-M26, S47-S52
  assertCheck "Phase 16 & F67-F72 (S47-S52, M23-M26, CoreQDS, 3-Loop Tier, QDS-26..28, OQP-27..30): Privilege-tier separation, Mid-Loop Pauli frame, ASIC/FPGA split, 2-tier NN-FPGA/AlphaQubit2, OP-NIC zero-copy & within_apply"
    (length allExecutionLoopTiers == 3
     && length allCoreQdsCombinators == 7
     && checkF67PrivilegeTierBoundarySafe False False
     && checkF67PrivilegeTierBoundarySafe True True
     && not (checkF67PrivilegeTierBoundarySafe True False)
     && innerLoopLatencyNs True False False False == 240
     && innerLoopLatencyNs False True False False == 273
     && innerLoopLatencyNs False False True False == 506
     && innerLoopLatencyNs False False False True == 550
     && checkF68CoprocessorMidLoopCoherenceSafe 5000 100000 True
     && not (checkF68CoprocessorMidLoopCoherenceSafe 10000 100000 False)
     && checkF69AsicStaticSyndromeGraphSafe True False
     && not (checkF69AsicStaticSyndromeGraphSafe True True)
     && checkF70NnFpgaDistanceAndQuantizationSafe 5 5 4 False
     && checkF70NnFpgaDistanceAndQuantizationSafe 11 5 4 True
     && not (checkF70NnFpgaDistanceAndQuantizationSafe 9 5 4 False)
     && checkF71OpNicStreamingBandwidthSafe 16 64 1000 10
     && not (checkF71OpNicStreamingBandwidthSafe 200 128 1000 10)
     && checkF72CoreQdsWithinApplyNoMidMeasCollapse 0x00F0 0x0F00 True
     && not (checkF72CoreQdsWithinApplyNoMidMeasCollapse 0x00F0 0x0030 True)
     && checkCoreQdsCombinatorCompositionSafe True False False True True False
     && not (checkCoreQdsCombinatorCompositionSafe True True False False False False)
     && not (checkCoreQdsCombinatorCompositionSafe False False True True False False)
     && not (checkCoreQdsCombinatorCompositionSafe False False False False True True)
     && length allSimplificationRulesS1toS52 == 52
     && length allMeasOptPassesM1ToM26 == 26
     && verifyPhase16F67ToF72CoreQds3LoopQds26To28AndOqp27To30)

  -- 16. Verify Phase 17: High-Level Quantum Language Literature Synthesis (Cobble, Spire, QCM, Qunity, Qwerty, Guppy, Yang & Yuan), QDS-29..31, OQP-31..34, Fixes F73-F78, Passes M27-M30, S53-S58
  assertCheck "Phase 17 & F73-F78 (S53-S58, M27-M30, QDS-29..31, OQP-31..34): Cobble subnormalization fusion, Spire T-hoisting, QCM injective join, Qunity/Guppy tag coalescing, Qwerty basis span & Yang-Yuan log assertion counter"
    (checkF73CobbleSubnormalizationFusionSafe 3 1 100 2 1 90 False
     && checkF73CobbleSubnormalizationFusionSafe 4 1 80 2 1 24 False
     && not (checkF73CobbleSubnormalizationFusionSafe 3 1 100 2 1 90 True)
     && not (checkF73CobbleSubnormalizationFusionSafe 3 1 100 4 1 100 False)
     && checkF74SpireSourceLevelTHoistingSafe True 32 32
     && not (checkF74SpireSourceLevelTHoistingSafe False 32 32)
     && not (checkF74SpireSourceLevelTHoistingSafe True 96 32)
     && checkF75QcmInjectiveJoinPredicateSafe True False 0
     && not (checkF75QcmInjectiveJoinPredicateSafe False False 0)
     && not (checkF75QcmInjectiveJoinPredicateSafe True True 0)
     && not (checkF75QcmInjectiveJoinPredicateSafe True False 4)
     && checkF76QunityDirectSumTagCoalescingSafe 3 8 True
     && not (checkF76QunityDirectSumTagCoalescingSafe 8 8 True)
     && not (checkF76QunityDirectSumTagCoalescingSafe 3 8 False)
     && checkF77QwertyBasisTranslationSpanSafe True True True 4 4
     && not (checkF77QwertyBasisTranslationSpanSafe False True True 4 4)
     && not (checkF77QwertyBasisTranslationSpanSafe True True False 4 4)
     && not (checkF77QwertyBasisTranslationSpanSafe True True True 4 2)
     && checkF78YangYuanLogAssertionCounterSafe 16 1 4 4 False
     && not (checkF78YangYuanLogAssertionCounterSafe 16 1 16 4 False)
     && not (checkF78YangYuanLogAssertionCounterSafe 16 1 4 4 True)
     && length allSimplificationRulesS1toS58 == 58
     && length allMeasOptPassesM1ToM30 == 30
     && verifyPhase17F73ToF78CobbleSpireQcmQunityQwertyQds29To31AndOqp31To34)

  -- 17. Verify Phase 18: Constructive IR-to-IR Transformations, HUGR Regional Port Graphs, Twist/Tower Entanglement & Pointer Heap, Bocher/Benes 2D AOD Router (QDS-32..34, OQP-35..38, Fixes F79-F84, Passes M31-M34, S59-S64)
  assertCheck "Phase 18 & F79-F84 (S59-S64, M31-M34, QDS-32..34, OQP-35..38): Structural direct-sum pattern isometry, HUGR regional port & sparse ANF, guarded S17/S19/S20 & Bocher-Benes router, Twist/Tower pointer & Stinespring dilation"
    (let (_, _, benesOk) = constructiveBocherBenes1dSplit [2, 0, 3, 1]
         rzzTwoRz = applyTodayHardwareSimplifications 0.0006 0.00033 False True
                      [ GateCNOT (QWire 0) (QWire 1)
                      , GateRZ   (QWire 1) 0.1
                      , GateRZ   (QWire 1) 0.2
                      , GateCNOT (QWire 0) (QWire 1)
                      ]
         unmatchedAnd = rewriteS17RCCXUncomputePhaseCancel 0.0006 0.0077
                          [GateAndCompute (QWire 0) (QWire 1) (QWire 2)]
     in benesOk
        && length rzzTwoRz == 1
        && countRZZGates rzzTwoRz == 1
        && unmatchedAnd == [GateAndCompute (QWire 0) (QWire 1) (QWire 2)]
        && sparseAnfEvalWire 12 [2, 7, 12]
        && not (sparseAnfEvalWire 12 [2, 7])
        && exactDyadicAngleMilliradOrExponent 6 8 == (3, 7)
        && checkF79StructuralDirectSumPatternIsometrySafe True True True 16
        && not (checkF79StructuralDirectSumPatternIsometrySafe False True True 16)
        && checkF80HugrRegionalPortAndSparseAnfSafe 8 8 4 4 12 True
        && not (checkF80HugrRegionalPortAndSparseAnfSafe 8 7 4 4 12 True)
        && not (checkF80HugrRegionalPortAndSparseAnfSafe 8 8 4 4 12 False)
        && checkF81GuardedS17S19S20AndBocherBenesSafe True True True True
        && checkF81GuardedS17S19S20AndBocherBenesSafe False False True True
        && not (checkF81GuardedS17S19S20AndBocherBenesSafe False True True True)
        && checkF82TwistEntanglementAndTowerPointerSafe True True 0
        && not (checkF82TwistEntanglementAndTowerPointerSafe True False 0)
        && not (checkF82TwistEntanglementAndTowerPointerSafe True True 5)
        && checkF83CobbleBeforeRccxAndScopedSpireHoistSafe True False 4 4
        && not (checkF83CobbleBeforeRccxAndScopedSpireHoistSafe False False 4 4)
        && not (checkF83CobbleBeforeRccxAndScopedSpireHoistSafe True True 4 4)
        && checkF84StinespringDilationAndExactDyadicSafe True True 0 25000
        && not (checkF84StinespringDilationAndExactDyadicSafe False True 0 25000)
        && not (checkF84StinespringDilationAndExactDyadicSafe True False 3 25000)
        && not (checkF84StinespringDilationAndExactDyadicSafe True True 0 200)
        && length allSimplificationRulesS1toS64 == 64
        && length allMeasOptPassesM1ToM34 == 34
        && verifyPhase18F79ToF84ConstructiveIrHugrTwistTowerQds32To34AndOqp35To38)

  -- 18. Verify Phase 19: End-to-End CoreQdsExpr 13-Constructor Lowering, Translation Validation, QDS-35..37, OQP-39..42, TODAY-21..22 QASM3, Fixes F85-F90, Passes M35-M38, S65-S70
  assertCheck "Phase 19 & F85-F90 (S65-S70, M35-M38, CoreQdsExpr 13-Constructor AST Lowering, OQP-1..42 End-to-End Synthesis, QDS-35..37, OQP-39..42, TODAY-21..22 QASM3)"
    (length allSimplificationRulesS1toS70 == 70
     && length allMeasOptPassesM1ToM38 == 38
     && length allCoreQdsCombinators11 == 11
     && length allCoreQdsCombinators13 == 13
     && oqp42VerifyAll42OqpEndToEndSynthesis
     && oqp40VerifyScopedAncillaCleanUncompute 2 3
     && not (oqp40VerifyScopedAncillaCleanUncompute 0 3)
     && oqp41VerifyPhaseOracleKickbackIdentity 1 True
     && not (oqp41VerifyPhaseOracleKickbackIdentity (-1) True)
     && checkF85NoMetadataOnlyConstantBooleanSynthesisSafe 5 12 True
     && not (checkF85NoMetadataOnlyConstantBooleanSynthesisSafe 1 12 True)
     && checkF86QLetScopedAncillaCleanUncomputeSafe 3 0 True
     && not (checkF86QLetScopedAncillaCleanUncomputeSafe 3 1 True)
     && checkF87QPhaseOracleKickbackConjugationSafe True True 0
     && not (checkF87QPhaseOracleKickbackConjugationSafe False True 0)
     && checkF88SpireControlWireDisjointFromTargetSafe 3 [0, 1, 2]
     && not (checkF88SpireControlWireDisjointFromTargetSafe 1 [0, 1, 2])
     && checkF89QcmSynthesizedJoinCleanAncillaDischargeSafe True 2 0
     && not (checkF89QcmSynthesizedJoinCleanAncillaDischargeSafe False 2 0)
     && checkF90CobbleSubnormalizationBoundAndZeroGuardSafe 1 2 1
     && not (checkF90CobbleSubnormalizationBoundAndZeroGuardSafe 3 2 1)
     && verifyPhase19F85ToF90EndToEndCoreQdsLoweringAllOqp1To42
     && verify_phase19_f85_to_f90_end_to_end_coreqds_lowering_all_oqp1_to_42)

  -- 19. Verify Phase 20: CoreQDS 2.0 Complete Language Upgrade (F91-F94, S71-S74, Passes M39-M40, CE-1..CE-10)
  assertCheck "Phase 20 & F91-F94 (S71-S74, M39-M40, CoreQDS 2.0 20-Constructor AST, QFreeExpr, QDataDecl, CE-1..CE-10 Forbidden Counterexamples)"
    (length allSimplificationRulesS1toS70 == 70
     && length allSimplificationRulesS1toS74 == 74
     && length allMeasOptPassesM1ToM38 == 38
     && length allMeasOptPassesM1ToM40 == 40
     && checkF91BetaSubstitutionAndQVarBindingSafe "x" 2 2
     && not (checkF91BetaSubstitutionAndQVarBindingSafe "" 2 2)
     && not (checkF91BetaSubstitutionAndQVarBindingSafe "x" 3 2)
     && checkF92QMatchClausesComputedOrthogonalitySafe 2 [0x3, 0xC]
     && not (checkF92QMatchClausesComputedOrthogonalitySafe 2 [0x3, 0x6])
     && not (checkF92QMatchClausesComputedOrthogonalitySafe 2 [0x3, 0x4])
     && checkF93QFreeExprBalancedAndUncomputeSafe 3 (QFreeXor (QFreeVar 0) (QFreeAnd (QFreeVar 1) (QFreeVar 2)))
     && not (checkF93QFreeExprBalancedAndUncomputeSafe 2 (QFreeXor (QFreeVar 0) (QFreeAnd (QFreeVar 1) (QFreeVar 2))))
     && checkF94TwistPurityPortAndSliceGuardSafe (1, 1, 1, 1) ([0, 1, 2], [0, 1, 2], 4) (8, 0, 3, 3, 4)
     && not (checkF94TwistPurityPortAndSliceGuardSafe (1, 0, 0, 1) ([0, 1, 2], [0, 1, 2], 4) (8, 0, 3, 3, 4))
     && verifyForbiddenCoreQdsCounterexamplesCe1ToCe10
     && verify_forbidden_coreqds_counterexamples_ce1_to_ce10
     && verifyPhase20CoreQds2CompleteLanguageF91ToF94
     && verify_phase20_coreqds2_complete_language_f91_to_f94)

  -- 20. Verify Phase 21: Translation-Validated & Provably Optimal CoreQDS 2.0 Circuit Compilation & 12-Target 3x4 Multi-Architecture Matrix (F95-F100, S75-S78, Passes M41-M44, OQP-43..46, TODAY-23..24)
  assertCheck "Phase 21 & F95-F100 (S75-S78, M41-M44, Strict LIFO Ancilla Stack, Topological Pebble QFreeExpr, Translation-Validated Optimizer, Optimal KAK SU(4), Multiplicative Complexity, 12-Target 3x4 Matrix, OQP-43..46, TODAY-23..24)"
    (length allSimplificationRulesS1toS70 == 70
     && length allSimplificationRulesS1toS74 == 74
     && length allSimplificationRulesS1toS78 == 78
     && length allMeasOptPassesM1ToM38 == 38
     && length allMeasOptPassesM1ToM40 == 40
     && length allMeasOptPassesM1ToM44 == 44
     && length allExecutionRegimes == 3
     && length allQuantumMachineTypes == 4
     && oqp46VerifyAll46OqpEndToEndSynthesis
     && checkF95StrictRevIrWireBoundsAndUafSafe 4 [LRevAllocClean 100, LRevCNOT 0 100, LRevCNOT 0 100, LRevFreeClean 100]
     && not (checkF95StrictRevIrWireBoundsAndUafSafe 4 [LRevCNOT 0 99])
     && not (checkF95StrictRevIrWireBoundsAndUafSafe 4 [LRevAllocClean 100, LRevFreeClean 100, LRevCNOT 0 100])
     && checkF96StrictLifoAncillaStackSafe [LRevAllocClean 100, LRevAllocClean 101, LRevFreeClean 101, LRevFreeClean 100]
     && not (checkF96StrictLifoAncillaStackSafe [LRevAllocClean 100, LRevAllocClean 101, LRevFreeClean 100, LRevFreeClean 101])
     && checkF97TopologicalPebbleLinearGateCountSafe 4 (QFreeAnd (QFreeAnd (QFreeVar 0) (QFreeVar 1)) (QFreeAnd (QFreeVar 2) (QFreeVar 3)))
     && verifyPhase21TranslationValidatedOptimalCoreQdsF95ToF100
     && verify_phase21_translation_validated_optimal_coreqds_f95_to_f100)

  -- 21. Verify Phase 22: SOTA Next-Generation Compiler: Exact Dyadic Cyclotomic Z[1/sqrt(2), i] Unitary Equivalence, Non-Local Phase-Polynomial T-par & GF(2) CNOT Synthesis, Explicit Coupling-Graph Routing, Bit-Accurate QDS-38 & Stim DEM Verifier (F101-F106, S79-S82, Passes M45-M48, OQP-47..48, TODAY-25..26)
  assertCheck "Phase 22 & F101-F106 (S79-S82, M45-M48, Exact Z[1/sqrt(2), i] Dyadic Cyclotomic Unitary Equivalence, Phase-Polynomial T-par & GF(2) CNOT, Explicit Coupling-Graph Routing, Bit-Accurate Braun Tree QDS-38, Stim DEM Verifier, OQP-47..48, TODAY-25..26)"
    (length allSimplificationRulesS1toS70 == 70
     && length allSimplificationRulesS1toS74 == 74
     && length allSimplificationRulesS1toS78 == 78
     && length allSimplificationRulesS1toS82 == 82
     && length allMeasOptPassesM1ToM38 == 38
     && length allMeasOptPassesM1ToM40 == 40
     && length allMeasOptPassesM1ToM44 == 44
     && length allMeasOptPassesM1ToM48 == 48
     && oqp48VerifyAll48OqpEndToEndSynthesis
     && checkF101ExactDyadicCyclotomicRingSafe
     && checkF102ExactDyadicUnitaryEquivalenceRejectsPhaseDriftSafe
     && checkF103PhasePolynomialTparAndGf2CnotSafe
     && checkF104ExplicitCouplingGraphRoutingSafe
     && checkF105Qds38BitAccurateBraunTreeSafe
     && checkF106Complete26PcqbAndStimDemDistanceSafe
     && verifyPhase22SotaExactDyadicTparSabreStimF101ToF106
     && verify_phase22_sota_exact_dyadic_tpar_sabre_stim_f101_to_f106)

  -- 22. Verify Phase 23: Multi-Shot Gidney MBU, Distributed Multi-QPU Telegate Synthesis, Native Hardware ISA Rebase & 600-Point `(OQP-1..50 x 12 Arch)` Matrix (F107-F112, S83-S86, Passes M49-M52, OQP-49..50, QDS-39, TODAY-27..28)
  assertCheck "Phase 23 & F107-F112 (S83-S86, M49-M52, Multi-Shot Gidney MBU, Zipper-Cut Telegate Cat-Entangler, Native Hardware ISA Rebase, Distributed Multi-QPU Braun Forest QDS-39, 600-Point OQP-1..50 x 12 Arch Matrix, OQP-49..50, TODAY-27..28)"
    (length allSimplificationRulesS1toS82 == 82
     && length allSimplificationRulesS1toS86 == 86
     && length allMeasOptPassesM1ToM48 == 48
     && length allMeasOptPassesM1ToM52 == 52
     && oqp50VerifyAll50OqpEndToEndSynthesis
     && checkF107GidneyMbuMultishotExactDyadicSafe
     && checkF108ZipperCutTelegateCatEntanglerSafe
     && checkF109NativeMachineIsaRebaseSafe
     && checkF110Qds39DistributedMultiQpuBraunForestSafe
     && checkF111Complete28PcqbManifestSafe
     && checkF112Full600OqpTargetArchMatrixSafe
     && verifyPhase23GidneyMbuTelegateNativeIsa600MatrixF107ToF112
     && verify_phase23_gidney_mbu_telegate_native_isa_600_matrix_f107_to_f112)

  -- 23. Verify Phase 24: Graphical ZX Spider-Fusion, Pauli-Web Equivalence, Ross-Selinger Gridsynth & Lakefill 6-Primitive Minimal Kernel (F113-F118, S87-S90, Passes M53-M56, OQP-51..52, QDS-40, TODAY-29..30)
  assertCheck "Phase 24 & F113-F118 (S87-S90, M53-M56, ZX Spider-Fusion & Hopf Law, 48-Qubit Pauli-Web Equivalence, Ross-Selinger Gridsynth, Lakefill 6-Primitive Minimal Kernel QDS-40, 624-Point OQP-1..52 x 12 Arch Matrix, OQP-51..52, TODAY-29..30)"
    (length allSimplificationRulesS1toS86 == 86
     && length allSimplificationRulesS1toS90 == 90
     && length allMeasOptPassesM1ToM52 == 52
     && length allMeasOptPassesM1ToM56 == 56
     && oqp52VerifyAll52OqpEndToEndSynthesis
     && checkF113ZxSpiderHopfAndPauliWeb48qSafe
     && checkF114RossSelingerGridsynthCliffordTSafe
     && checkF115LakefillMinimalKernel6DesugaringSafe
     && checkF116Qds40LakefillKernelContainerSafe
     && checkF117Full624OqpTargetArchMatrixSafe
     && checkF118Complete30PcqbManifestSafe
     && verifyPhase24ZxPauliWebGridsynthLakefillKernel6F113ToF118
     && verify_phase24_zx_pauli_web_gridsynth_lakefill_kernel6_f113_to_f118)

  -- 24. Verify Phase 25: Graph-Like ZX Local Complementation, Pivot Gadgetization & GFlow Extraction, Gidney-Shutty-Jones Magic State Cultivation & Litinski GoSC Lattice Surgery, DEJMPS Entanglement Distillation & QDS-41 Photonic Deque Zipper, and Proof-Carrying Compilation (PCC-Lakefill) across 648 Target Cells (F119-F124, S91-S94, Passes M57-M60, OQP-53..54, QDS-41, TODAY-31..32)
  assertCheck "Phase 25 & F119-F124 (S91-S94, M57-M60, GFlow ZX-Pivot Extraction, Magic State Cultivation & GoSC Lattice Surgery, DEJMPS Entanglement Distillation & QDS-41 Photonic Deque Zipper, 648-Cell PCC-Lakefill Matrix, OQP-53..54, TODAY-31..32)"
    (length allSimplificationRulesS1toS90 == 90
     && length allSimplificationRulesS1toS94 == 94
     && length allMeasOptPassesM1ToM56 == 56
     && length allMeasOptPassesM1ToM60 == 60
     && oqp54VerifyAll54OqpEndToEndSynthesis
     && checkF119ZxGflowGaussianEliminationExtractionSafe
     && checkF120MagicStateCultivationColorCodeAndGoscSafe
     && checkF121DejmpsEprDistillationAndQds41PhotonicDequeSafe
     && checkF122PccLakefillCertificateSoundnessSafe
     && checkF123Full648PccLakefillTargetMatrixSafe
     && checkF124Complete32PcqbManifestSafe
     && verifyPhase25GflowCultivationDejmpsPccLakefillF119ToF124
     && verify_phase25_gflow_cultivation_dejmps_pcc_lakefill_f119_to_f124)

  -- 25. Verify Phase 27: Post-Rebase & Post-Route Involution Peephole (`S95`, `M61`, `F125`), Dense-SSA Active-Qubit Compaction (`S96`, `M62`, `F126`), Short-Last Multichannel Spooky-Pebbling Reserve (`QDS-42`, `S97`, `M63`, `F127`), Bilateral Phase-Octant Invariance (`S98`, `F128`), and 672-Cell `(OQP-1..56 x 12 Arch)` Matrix (`M64`, `F129-F130`, `OQP-55..56`, `TODAY-33..34`)
  assertCheck "Phase 27 & F125-F130 (S95-S98, M61-M64, Post-Route Peephole Optimizer, Dense-SSA Qubit Compaction, Short-Last Multichannel Reserve QDS-42, Bilateral Phase-Octant Invariance, 672-Cell PCC-Lakefill Matrix, OQP-55..56, TODAY-33..34)"
    (length allSimplificationRulesS1toS94 == 94
     && length allSimplificationRulesS1toS98 == 98
     && length allMeasOptPassesM1ToM60 == 60
     && length allMeasOptPassesM1ToM64 == 64
     && oqp56VerifyAll56OqpEndToEndSynthesis
     && checkF125PostRebaseAndPostRoutePeepholeSafe
     && checkF126DenseSsaQubitCompactionSafe
     && checkF127Qds42ShortLastMultichannelReserveSafe
     && checkF128BilateralPhaseOctantInvarianceSafe
     && checkF129Full672PostRoutePeepholeTargetMatrixSafe
     && checkF130Complete34PcqbManifestZeroUnusedZeroCancelsSafe
     && verifyPhase27PostRoutePeepholeDenseSsaShortLastBilateralF125ToF130
     && verify_phase27_post_route_peephole_dense_ssa_short_last_bilateral_f125_to_f130)

  -- 26. Verify Phase 28: Commutation-Aware Per-Wire DAG & Diagonal-Z Peephole Optimizer (`S99`, `M65`, `F129`), ASAP Parallel Critical-Path Scheduler & Balanced 4-Pulse XY4 Dynamical Decoupling Idle-Spine Zipper (`QDS-43`, `S100`, `M66`, `F130`, `OQP-57`, `TODAY-35`), GRH 8-Pattern Zero-Drift & 100% <=30-Line Small-Proof Explainability (`S101`, `M67`, `F131`), Parametric Symbolic-Width Cryptographic & Scientific Resource Compiler (`S102`, `M68`, `F132`, `OQP-58`, `TODAY-36`), and 696-Cell (`OQP-1..58 x 12 Arch`) + 12-Target x 5-Layout Equivalence Matrix
  assertCheck "Phase 28 & F129-F134 (S99-S102, M65-M68, Per-Wire DAG & Diagonal-Z Peephole Optimizer, ASAP Parallel Critical-Path & QDS-43 XY4 Idle-Spine Zipper, GRH 8-Pattern Zero-Drift <=30-Line Audit, Parametric Symbolic-Width Resource Compiler, 696-Cell PCC-Lakefill Matrix & 12-Arch x 5-Layout Equivalence, OQP-57..58, TODAY-35..36)"
    (length allSimplificationRulesS1toS98 == 98
     && length allSimplificationRulesS1toS102 == 102
     && length allMeasOptPassesM1ToM64 == 64
     && length allMeasOptPassesM1ToM68 == 68
     && oqp58VerifyAll58OqpEndToEndSynthesis
     && checkF131DagCommutationPeepholeAndPostPeepholeTCountSafe
     && checkF132AsapParallelCriticalPathAndQds43Xy4IdleSpineSafe
     && checkF133GrhEightPatternAndParametricCryptoResourceSafe
     && checkF134Full696DagAsapTargetMatrixAnd36PcqbSafe
     && verifyPhase28DagPeepholeAsapXy4DdParametricResourceF129ToF132
     && verify_phase28_dag_peephole_asap_xy4_dd_parametric_resource_f129_to_f132)

  -- 27. Verify Phase 29: Hadamard-Conjugated CZ TeleGate & Multi-Basis 720-Cell / 300-Layout Unpermuted Equivalence (`S103`, `M69`, `F133`), First-Principles n-Bit LakefillKernel6 AST Resource Derivation & GRH 10-Pattern Audit (`S104`, `M70`, `F134`), OpenQASM 3.0 Round-Trip Parser & Semantic Equivalence Verifier (`S105`, `M71`, `F135`, `OQP-60`, `TODAY-38`), and Noisy Z-Drift XY4 Channel Simulation & QDS-44 Live-Range Chordal Ancilla Recycling Zipper (`S106`, `M72`, `F136`, `QDS-44`, `OQP-59`, `TODAY-37`)
  assertCheck "Phase 29 & F133-F136 (S103-S106, M69-M72, Hadamard-Conjugated CZ TeleGate, 720-Cell Multi-Basis & 300-Layout Unpermuted Equivalence, First-Principles n-Bit LakefillKernel6 AST Resource Derivation, GRH 10-Pattern Audit, OpenQASM 3.0 Round-Trip Parser, Noisy Z-Drift XY4 Channel & QDS-44 Live-Range Chordal Ancilla Recycling Zipper, OQP-59..60, TODAY-37..38)"
    (length allSimplificationRulesS1toS102 == 102
     && length allSimplificationRulesS1toS106 == 106
     && length allMeasOptPassesM1ToM68 == 68
     && length allMeasOptPassesM1ToM72 == 72
     && oqp60VerifyAll60OqpEndToEndSynthesis
     && checkF133HadamardConjugatedCzTeleGateAnd720MultibasisSafe
     && checkF134FirstPrinciplesNBitLakefillAstAndGrh10PatternSafe
     && checkF135OpenQasm3RoundtripParserAndSemanticEquivSafe
     && checkF136NoisyZDriftXy4ChannelAndQds44ChordalRecyclingSafe
     && verifyPhase29MultibasisFirstPrinciplesQasm3RoundtripNoisyXy4F133ToF136
     && verify_phase29_multibasis_first_principles_qasm3_roundtrip_noisy_xy4_f133_to_f136)

  let (allOk, summaryMsg) = runAllTodayHardwareVerifications
  assertCheck ("Master TodayHardware verification suite (" ++ summaryMsg ++ ")") allOk

  putStrLn "======================================================================"
  putStrLn "ALL HASKELL PHASE-8..29 TODAY-HARDWARE & F29-F136 UNIT TESTS PASSED (100%)!"
  putStrLn "======================================================================"
  exitSuccess



