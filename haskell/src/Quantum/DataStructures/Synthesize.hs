{-# LANGUAGE StrictData #-}

-- |
-- Module      : Quantum.DataStructures.Synthesize
-- Description : Top-Level Quantum Circuit Synthesis & Today-Available Hardware Compiler
--               Re-exporting `Circuit`, `Simplify` (`S1–S20`, `M1–M5`), and `TodayHardware`.
module Quantum.DataStructures.Synthesize
  ( module Quantum.DataStructures.Circuit
  , module Quantum.DataStructures.Simplify
  , module Quantum.DataStructures.TodayHardware
  , module Quantum.DataStructures.Types
  , module Quantum.DataStructures.Verify
  , SynthesizedTodayCircuit(..)
  , synthesizeForTodayHardware
  ) where

import Quantum.DataStructures.Circuit
import Quantum.DataStructures.Simplify
import Quantum.DataStructures.TodayHardware
import Quantum.DataStructures.Types
import Quantum.DataStructures.Verify

-- | Complete synthesis report for a circuit compiled to a 2025–2026 hardware profile:
data SynthesizedTodayCircuit = SynthesizedTodayCircuit
  { stcProfile       :: !HardwareProfileToday
  , stcSpec          :: !TodayHardwareSpec
  , stcTier2IR       :: !MLRevIR
  , stcTier3ISA      :: !LLMachineISA
  , stcSurvivalGrade :: !SurvivalGrade
  } deriving (Eq, Show)

-- | Compile a high-level Okasaki `HLQdsIR` program through the shared `Tier 1 -> Tier 2`
--   pipeline and lower to `Tier 3 (LLMachineISA)` + `SurvivalGrade` for a target `HardwareProfileToday`:
synthesizeForTodayHardware :: HardwareProfileToday -> Int -> HLQdsIR -> SynthesizedTodayCircuit
synthesizeForTodayHardware profile logicalQubits hlIR =
  let spec   = getTodayHardwareSpec profile
      tier2  = lowerTier1ToTier2 hlIR
      (revG, _, _) = applyMeasOptPassM1toM5 (DialectTodayHardware profile) tier2
      tier3  = lowerTier2ToTier3 (DialectTodayHardware profile) tier2
      sGrade = computeSurvivalGrade profile logicalQubits revG
  in SynthesizedTodayCircuit
       { stcProfile       = profile
       , stcSpec          = spec
       , stcTier2IR       = tier2
       , stcTier3ISA      = tier3
       , stcSurvivalGrade = sGrade
       }
