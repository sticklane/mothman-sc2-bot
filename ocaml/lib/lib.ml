(******************************************************************************)
(* lib.ml                                                                     *)
(* ========================================================================== *)
(* Top-level OCaml library module exposing `Circuit`, `Simplify` (`S1–S20`),  *)
(* and `Today_hardware` (`Willow 105Q`, `Heron R2 156Q`, `Quantinuum H2 56Q`, *)
(* `Bluvstein Neutral Atom 3000Q/48L`).                                       *)
(******************************************************************************)

module Circuit        = Circuit
module Simplify       = Simplify
module Today_hardware = Today_hardware
module TodayHardware  = Today_hardware

include Circuit
include Simplify
include Today_hardware
