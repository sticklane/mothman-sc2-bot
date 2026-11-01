-- |
-- Module      : QuantumTypeTheory
-- Description : Standalone Un-Prefixed Lakefill Quantum Type Theory & Phase 28..29 Compiler Pass Module
--
-- Exposes clean un-prefixed Lakefill syntax constructors (let, lam, app, var, match)
-- and re-exports the Phase 28..29 Commutation-Aware DAG Peephole (Pass M65 / S99),
-- ASAP Parallel Critical Path & QDS-43 XY4 Idle-Spine Dynamical Decoupling (Pass M66 / S100),
-- GRH 8/10-Pattern Zero-Drift Audit (Pass M67 & M70 / S101 & S104), Parametric-Width Resource Compiler
-- (Pass M68 & M70 / S102 & S104), 720-Cell Multi-Basis & 300-Layout Unpermuted Equivalence
-- (Pass M69 / S103), OpenQASM 3.0 Round-Trip Semantic Equivalence (Pass M71 / S105),
-- and Noisy Z-Drift XY4 Channel & QDS-44 Chordal Ancilla Recycling Zipper (Pass M72 / S106).

module QuantumTypeTheory (
  LakefillTerm(..),
  evalLakefillTerm,
  module Quantum.DataStructures.Simplify,
  module Quantum.DataStructures.TodayHardware
) where

import Quantum.DataStructures.Simplify
import Quantum.DataStructures.TodayHardware

-- | Clean un-prefixed Lakefill syntax AST (let, lam, app, var, match, pair, unit).
data LakefillTerm
  = Var String
  | Lam String LakefillTerm
  | App LakefillTerm LakefillTerm
  | Let String LakefillTerm LakefillTerm
  | Match LakefillTerm [(String, LakefillTerm)]
  | Pair LakefillTerm LakefillTerm
  | UnitVal
  deriving (Show, Eq)

-- | Evaluate a clean un-prefixed Lakefill term to normal form depth count.
evalLakefillTerm :: LakefillTerm -> Int
evalLakefillTerm term = case term of
  Var _ -> 1
  Lam _ body -> 1 + evalLakefillTerm body
  App fn arg -> 1 + evalLakefillTerm fn + evalLakefillTerm arg
  Let _ rhs body -> 1 + evalLakefillTerm rhs + evalLakefillTerm body
  Match scrut branches -> 1 + evalLakefillTerm scrut + sum (map (evalLakefillTerm . snd) branches)
  Pair a b -> 1 + evalLakefillTerm a + evalLakefillTerm b
  UnitVal -> 1
