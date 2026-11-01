{-# LANGUAGE StrictData #-}

-- |
-- Module      : Quantum.DataStructures.Circuit
-- Description : Core Reversible & Hardware-Native Quantum Gate AST (`RevGate`, `TodayNativeGate`)
--               supporting Simplifications S1-S20 and Today-Available 2025-2026 Quantum Hardware.
module Quantum.DataStructures.Circuit
  ( QWire(..)
  , RevGate(..)
  , daggerGate
  , daggerCircuit
  , countToffolis
  , countCSWAPs
  , countBellPairs
  , countCZGates
  , countMidCircuitMeas
  , countVirtualRZGates
  , countRZZGates
  , countNativeCCZ
  , countNativeISWAP
  ) where

-- | Physical or logical quantum wire identifier.
newtype QWire = QWire { unQWire :: Int }
  deriving (Eq, Ord, Show)

-- | Extended Reversible, Measurement-Based & Hardware-Native Quantum Gate AST (`S1-S20`):
data RevGate
  = GateX           !QWire                      -- ^ Pauli-X (NOT)
  | GateH           !QWire                      -- ^ Hadamard
  | GateZ           !QWire                      -- ^ Pauli-Z
  | GateSX          !QWire                      -- ^ Native sqrt(X) on Willow / Heron R2
  | GateRZ          !QWire !Double              -- ^ Physical Z-axis rotation by angle phi (rad)
  | GateVirtualRZ   !QWire !Double              -- ^ S19: 0 ns, 0-error software frame Z rotation
  | GateCNOT        !QWire !QWire               -- ^ Controlled-NOT (ctrl, tgt)
  | GateCZ          !QWire !QWire               -- ^ Native Controlled-Z (ctrl, tgt)
  | GateRZZ         !QWire !QWire !Double       -- ^ S20: Quantinuum H2 native exp(-i phi/2 Z (x) Z)
  | GateNativeISWAP !QWire !QWire               -- ^ S18: Neutral-Atom / SC native iSWAP pulse
  | GateCCX         !QWire !QWire !QWire        -- ^ Standard Toffoli (ctrl1, ctrl2, tgt)
  | GateAndCompute  !QWire !QWire !QWire        -- ^ Gidney temporary AND compute into clean |0>
  | GateRCCX        !QWire !QWire !QWire        -- ^ S17: Margolus 3-CZ relative-phase Toffoli
  | GateRCCXDag     !QWire !QWire !QWire        -- ^ S17: Adjoint Margolus 3-CZ relative-phase uncompute
  | GateNativeCCZ   !QWire !QWire !QWire        -- ^ S18: Bluvstein Rydberg blockade 1-pulse CCZ
  | GateCSWAP       !QWire !QWire !QWire        -- ^ Fredkin (ctrl, swapA, swapB)
  | GateHMR_CZ      !QWire !QWire !QWire        -- ^ Hadamard-Measure-Reset + CZ fixup (pebble, c1, c2)
  | GateMCMR        !QWire !Int                 -- ^ S20: Mid-Circuit Measurement & Reset (wire, zoneId)
  | GateCatEnt      !QWire !QWire               -- ^ Cross-QPU Cat-Entangler (1 Bell pair)
  | GateCatDis      !QWire !QWire               -- ^ Cross-QPU HMR+CZ Cat-Disentangler (0 Bell pairs)
  deriving (Eq, Show)

-- | Exact syntactic adjoint (dagger) of a gate (`S1-S20`):
daggerGate :: RevGate -> RevGate
daggerGate g = case g of
  GateX w              -> GateX w
  GateH w              -> GateH w
  GateZ w              -> GateZ w
  GateSX w             -> GateSX w
  GateRZ w phi         -> GateRZ w (negate phi)
  GateVirtualRZ w phi  -> GateVirtualRZ w (negate phi)
  GateCNOT c t         -> GateCNOT c t
  GateCZ c t           -> GateCZ c t
  GateRZZ a b phi      -> GateRZZ a b (negate phi)
  GateNativeISWAP a b  -> GateNativeISWAP a b
  GateCCX c1 c2 t      -> GateCCX c1 c2 t
  GateAndCompute c1 c2 t -> GateHMR_CZ t c1 c2
  GateRCCX c1 c2 t     -> GateRCCXDag c1 c2 t
  GateRCCXDag c1 c2 t  -> GateRCCX c1 c2 t
  GateNativeCCZ c1 c2 t -> GateNativeCCZ c1 c2 t
  GateCSWAP c a b      -> GateCSWAP c a b
  GateHMR_CZ t c1 c2   -> GateAndCompute c1 c2 t
  GateMCMR w z         -> GateMCMR w z
  GateCatEnt q0 q1     -> GateCatDis q0 q1
  GateCatDis q0 q1     -> GateCatEnt q0 q1

daggerCircuit :: [RevGate] -> [RevGate]
daggerCircuit = reverse . map daggerGate

countToffolis :: [RevGate] -> Int
countToffolis = foldr (\g acc -> case g of
  GateCCX {}        -> acc + 1
  GateAndCompute {} -> acc + 1
  _                 -> acc) 0

countCSWAPs :: [RevGate] -> Int
countCSWAPs = foldr (\g acc -> case g of GateCSWAP {} -> acc + 1; _ -> acc) 0

countBellPairs :: [RevGate] -> Int
countBellPairs = foldr (\g acc -> case g of GateCatEnt {} -> acc + 1; _ -> acc) 0

-- | Total hardware 2-qubit CZ cost (counting RCCX / RCCXDag as 3 native CZs each):
countCZGates :: [RevGate] -> Int
countCZGates = foldr (\g acc -> case g of
  GateCZ {}      -> acc + 1
  GateCNOT {}    -> acc + 1
  GateRCCX {}    -> acc + 3
  GateRCCXDag {} -> acc + 3
  GateCCX {}     -> acc + 6
  _              -> acc) 0

-- | Total mid-circuit measurements (`GateHMR_CZ` and `GateMCMR`):
countMidCircuitMeas :: [RevGate] -> Int
countMidCircuitMeas = foldr (\g acc -> case g of
  GateHMR_CZ {} -> acc + 1
  GateMCMR {}   -> acc + 1
  _             -> acc) 0

countVirtualRZGates :: [RevGate] -> Int
countVirtualRZGates = foldr (\g acc -> case g of GateVirtualRZ {} -> acc + 1; _ -> acc) 0

countRZZGates :: [RevGate] -> Int
countRZZGates = foldr (\g acc -> case g of GateRZZ {} -> acc + 1; _ -> acc) 0

countNativeCCZ :: [RevGate] -> Int
countNativeCCZ = foldr (\g acc -> case g of GateNativeCCZ {} -> acc + 1; _ -> acc) 0

countNativeISWAP :: [RevGate] -> Int
countNativeISWAP = foldr (\g acc -> case g of GateNativeISWAP {} -> acc + 1; _ -> acc) 0
