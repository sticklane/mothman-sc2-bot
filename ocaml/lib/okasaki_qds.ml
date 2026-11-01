(******************************************************************************)
(* okasaki_qds.ml                                                             *)
(* ========================================================================== *)
(* Top-level root module for the `okasaki_qds` OCaml library, re-exporting    *)
(* `Circuit`, `Simplify` (`S1–S74`, `M1–M40`, CoreQDS 2.0), `Today_hardware`, *)
(* and `Lib`.                                                                 *)
(******************************************************************************)

module Circuit        = Circuit
module Simplify       = Simplify
module Today_hardware = Today_hardware
module TodayHardware  = Today_hardware
module Lib            = Lib

include Circuit
include Simplify
include Today_hardware
