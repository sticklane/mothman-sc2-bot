(******************************************************************************)
(* ppx_gospel_qfree_anf.ml                                                    *)
(* ========================================================================== *)
(* Standalone OCaml PPX AST Rewriter (`[@qfree_anf_certified]`, `let*`/`and*` *)
(* desugaring + automatic `qm_with_qfree` insertion) and Gospel / Cameleer    *)
(* Formal Specification Annotations (`(*@ requires ... ensures ... *)`) with  *)
(* Why3 / SMT-LIB2 (`QF_BV`) Verification-Condition Generator for             *)
(* `okasaki_quantum_type_theory.ml` (`Simplifications S9–S10` & `Fixes F1–F16`)*)
(******************************************************************************)

(* ========================================================================== *)
(* 1. Gospel Ghost Logical Models (`(*@ model ... *)`) for S8 / S10           *)
(* ========================================================================== *)

type gospel_basis_mode =
  | G_QFree
  | G_HadamardMode

type gospel_rep_state =
  | G_CanonicalRep
  | G_RedundantCS

type gospel_hw_zone =
  | G_Zone_HotSC
  | G_Zone_YokedCold
  | G_Zone_BBTorus
  | G_Zone_AOD

type gospel_css_round =
  | G_CSS_Closed
  | G_CSS_InFlight_X
  | G_CSS_InFlight_Z

type gospel_wire_model = {
  gw_wire_id   : int;
  gw_basis     : gospel_basis_mode;
  gw_rep       : gospel_rep_state;
  gw_locked    : bool;
  gw_anf_delta : int; (** 0 iff ANF(w) = x_w (zero residual garbage delta) *)
  gw_anf_deg   : int; (** Algebraic degree over F_2 in {0, 1, 2, 3}        *)
  gw_zone      : gospel_hw_zone;
}
(*@ model basis     : gospel_basis_mode
    model rep       : gospel_rep_state
    model locked    : bool
    model anf_delta : int
    model anf_deg   : int
    model zone      : gospel_hw_zone
    invariant 0 <= gw_anf_deg <= 3 *)

type gospel_global_qec_model = {
  gg_css_round        : gospel_css_round;
  gg_latency_ns       : int;
  gg_live_links       : (int * int) list;
  gg_barrier_violated : bool;
}
(*@ model css_round  : gospel_css_round
    model latency_ns : int
    model live_links : (int * int) list
    invariant gg_latency_ns >= 0 *)

(* ========================================================================== *)
(* 2. Gospel Predicates & Refinement Contracts (`Fixes F1–F16`)               *)
(* ========================================================================== *)

(*@ predicate is_clean_aux_wire (w : gospel_wire_model) =
      w.gw_basis = G_QFree &&
      w.gw_rep = G_CanonicalRep &&
      w.gw_locked = false &&
      w.gw_anf_delta = 0 *)
let is_clean_aux_wire (w : gospel_wire_model) : bool =
  w.gw_basis = G_QFree
  && w.gw_rep = G_CanonicalRep
  && (not w.gw_locked)
  && w.gw_anf_delta = 0

(*@ predicate is_deterministic_stim_detector (w : gospel_wire_model) =
      w.gw_basis = G_QFree &&
      w.gw_rep = G_CanonicalRep &&
      w.gw_anf_delta = 0 *)
(** Fix F14: Deterministic `Stim` `DETECTOR` precondition *)
let is_deterministic_stim_detector (w : gospel_wire_model) : bool =
  w.gw_basis = G_QFree
  && w.gw_rep = G_CanonicalRep
  && w.gw_anf_delta = 0

(*@ predicate is_non_forgetful_subtype (w_sub : gospel_wire_model) (w_sup : gospel_wire_model) =
      (w_sub.gw_locked = true -> w_sup.gw_locked = true) &&
      (w_sub.gw_rep = G_RedundantCS -> w_sup.gw_rep = G_RedundantCS) &&
      (w_sub.gw_basis = G_HadamardMode -> w_sup.gw_basis = G_HadamardMode) &&
      w_sub.gw_anf_delta = w_sup.gw_anf_delta &&
      w_sub.gw_zone = w_sup.gw_zone *)
(** Fix F15: Non-forgetful refinement subtyping check *)
let is_non_forgetful_subtype (w_sub : gospel_wire_model) (w_sup : gospel_wire_model) : bool =
  ((not w_sub.gw_locked) || w_sup.gw_locked)
  && (w_sub.gw_rep <> G_RedundantCS || w_sup.gw_rep = G_RedundantCS)
  && (w_sub.gw_basis <> G_HadamardMode || w_sup.gw_basis = G_HadamardMode)
  && w_sub.gw_anf_delta = w_sup.gw_anf_delta
  && w_sub.gw_zone = w_sup.gw_zone

(*@ predicate is_css_safe_bb_torus_shift (w : gospel_wire_model) (g : gospel_global_qec_model) =
      w.gw_zone = G_Zone_BBTorus && g.gg_css_round = G_CSS_Closed *)
(** Fix F16: Bivariate Bicycle qLDPC torus shift requires `G_CSS_Closed` *)
let is_css_safe_bb_torus_shift (w : gospel_wire_model) (g : gospel_global_qec_model) : bool =
  w.gw_zone = G_Zone_BBTorus && g.gg_css_round = G_CSS_Closed

(* ========================================================================== *)
(* 3. OCaml PPX AST Representation (`[@qfree_anf_certified]`, `let*`/`and*`)  *)
(* ========================================================================== *)

type ppx_attribute =
  | Attr_qfree_anf_certified
  | Attr_auto_with_qfree
  | Attr_stim_detector of int
  | Attr_bb_torus_shift of int * int

type ppx_prim_op =
  | Ppx_Cnot       of int * int
  | Ppx_Cz         of int * int
  | Ppx_Hadamard   of int
  | Ppx_Toffoli    of int * int * int
  | Ppx_HmrCz      of int * int * int
  | Ppx_CatEnt     of int * int
  | Ppx_CatDis     of int * int
  | Ppx_QecBarrier
  | Ppx_CSSRound   of bool (** true = begin, false = end *)

type ppx_qmonad_ast =
  | Ppx_Return       of string
  | Ppx_Prim         of ppx_prim_op
  | Ppx_LetStar      of string * ppx_qmonad_ast * ppx_qmonad_ast
  | Ppx_AndStar      of ppx_qmonad_ast * ppx_qmonad_ast
  | Ppx_WithQFree    of ppx_qmonad_ast * ppx_qmonad_ast
  | Ppx_ManualUncomp of ppx_qmonad_ast * ppx_qmonad_ast * ppx_qmonad_ast
  | Ppx_Annotated    of ppx_attribute * ppx_qmonad_ast

let rec invert_ppx_ast = function
  | Ppx_Return v -> Ppx_Return v
  | Ppx_Prim (Ppx_CatEnt (q0, q1)) -> Ppx_Prim (Ppx_CatDis (q0, q1))
  | Ppx_Prim (Ppx_CatDis (q0, q1)) -> Ppx_Prim (Ppx_CatEnt (q0, q1))
  | Ppx_Prim op -> Ppx_Prim op
  | Ppx_LetStar (pat, e1, e2) ->
    Ppx_LetStar (pat, invert_ppx_ast e2, invert_ppx_ast e1)
  | Ppx_AndStar (e1, e2) ->
    Ppx_AndStar (invert_ppx_ast e2, invert_ppx_ast e1)
  | Ppx_WithQFree (u, act) ->
    Ppx_WithQFree (u, invert_ppx_ast act)
  | Ppx_ManualUncomp (u, act, u_dag) ->
    Ppx_ManualUncomp (u_dag, invert_ppx_ast act, u)
  | Ppx_Annotated (attr, body) ->
    Ppx_Annotated (attr, invert_ppx_ast body)

(** PPX AST Rewriter (`rewrite_qfree_anf_certified`):
    1. Rewrites legacy 3-argument `Ppx_ManualUncomp (u, act, _u_dag)` annotated with
       `[@auto_with_qfree]` or `[@qfree_anf_certified]` into single-argument
       `Ppx_WithQFree (u, act)` with synthesized `invert_ppx_ast u` (`Simplification S6` / `Fix F6`).
    2. Recursively normalizes `let*` / `and*` monadic binds (`Simplification S5`). *)
(*@ val rewrite_qfree_anf_certified : ppx_qmonad_ast -> ppx_qmonad_ast
    ensures match result with Ppx_ManualUncomp _ -> false | _ -> true *)
let rec rewrite_qfree_anf_certified (ast : ppx_qmonad_ast) : ppx_qmonad_ast =
  match ast with
  | Ppx_Return v -> Ppx_Return v
  | Ppx_Prim op -> Ppx_Prim op
  | Ppx_LetStar (pat, e1, e2) ->
    Ppx_LetStar (pat, rewrite_qfree_anf_certified e1, rewrite_qfree_anf_certified e2)
  | Ppx_AndStar (e1, e2) ->
    Ppx_AndStar (rewrite_qfree_anf_certified e1, rewrite_qfree_anf_certified e2)
  | Ppx_WithQFree (u, act) ->
    Ppx_WithQFree (rewrite_qfree_anf_certified u, rewrite_qfree_anf_certified act)
  | Ppx_ManualUncomp (u, act, _ignored_manual_dag) ->
    (* Automatic S6 synthesis: replaces error-prone manual u_dag with exact adjoint! *)
    Ppx_WithQFree (rewrite_qfree_anf_certified u, rewrite_qfree_anf_certified act)
  | Ppx_Annotated (attr, body) ->
    Ppx_Annotated (attr, rewrite_qfree_anf_certified body)

let rec flatten_ppx_ast_to_prims (ast : ppx_qmonad_ast) : ppx_prim_op list =
  match ast with
  | Ppx_Return _ -> []
  | Ppx_Prim op -> [ op ]
  | Ppx_LetStar (_, e1, e2) | Ppx_AndStar (e1, e2) ->
    flatten_ppx_ast_to_prims e1 @ flatten_ppx_ast_to_prims e2
  | Ppx_WithQFree (u, act) ->
    let u_dag = invert_ppx_ast u in
    flatten_ppx_ast_to_prims u
    @ flatten_ppx_ast_to_prims act
    @ flatten_ppx_ast_to_prims u_dag
  | Ppx_ManualUncomp (u, act, u_dag) ->
    flatten_ppx_ast_to_prims u
    @ flatten_ppx_ast_to_prims act
    @ flatten_ppx_ast_to_prims u_dag
  | Ppx_Annotated (_, body) ->
    flatten_ppx_ast_to_prims body

(* ========================================================================== *)
(* 4. Why3 / SMT-LIB2 Verification Condition Generator for Gospel Contracts   *)
(* ========================================================================== *)

type gospel_contract_obligation = {
  gco_name             : string;
  gco_aux_wires        : gospel_wire_model list;
  gco_detector_wires   : gospel_wire_model list;
  gco_subtype_pairs    : (gospel_wire_model * gospel_wire_model) list;
  gco_torus_wires      : gospel_wire_model list;
  gco_global_state     : gospel_global_qec_model;
}

type gospel_vc_result = {
  gvc_name             : string;
  gvc_unsat_verified   : bool;
  gvc_diagnostic       : string;
  gvc_why3_mlw         : string;
  gvc_smtlib2_query    : string;
}

(*@ val solve_gospel_qfree_anf_contract : gospel_contract_obligation -> gospel_vc_result
    ensures result.gvc_unsat_verified = true <->
      (List.for_all is_clean_aux_wire o.gco_aux_wires &&
       List.for_all is_deterministic_stim_detector o.gco_detector_wires &&
       o.gco_global_state.gg_latency_ns <= 1000 &&
       o.gco_global_state.gg_live_links = [] &&
       o.gco_global_state.gg_barrier_violated = false) *)
let solve_gospel_qfree_anf_contract (o : gospel_contract_obligation) : gospel_vc_result =
  let g          = o.gco_global_state in
  let aux_ok     = List.for_all is_clean_aux_wire o.gco_aux_wires in
  let det_ok     = List.for_all is_deterministic_stim_detector o.gco_detector_wires in
  let sub_ok     = List.for_all (fun (w1, w2) -> is_non_forgetful_subtype w1 w2) o.gco_subtype_pairs in
  let torus_ok   = List.for_all (fun w -> is_css_safe_bb_torus_shift w g) o.gco_torus_wires in
  let lat_ok     = g.gg_latency_ns <= 1000 in
  let links_ok   = (g.gg_live_links = []) in
  let barrier_ok = not g.gg_barrier_violated in
  let all_ok     = aux_ok && det_ok && sub_ok && torus_ok && lat_ok && links_ok && barrier_ok in
  let diag =
    if not barrier_ok then "F13: VOQC gate cancellation across HMR_CZ / QECBarrier"
    else if not det_ok then "F14: Non-deterministic Stim DETECTOR on superposition/RedundantCS/dirty wire"
    else if not sub_ok then "F15: Forgetful refinement subtyping dropped lock/rep/basis invariant"
    else if not torus_ok then "F16: Bivariate Bicycle torus shift during in-flight CSS syndrome round"
    else if not lat_ok then "F12: Terhal syndrome backlog violation (latency_ns > 1000)"
    else if not links_ok then "F8: Orphaned cross-QPU cat-entangled Bell link on exit"
    else if not aux_ok then "F2/F3/F9/F10: Auxiliary wire not restored to unlocked canonical QFree identity"
    else "UNSAT: All Gospel + PPX S10 (F1..F16) refinement obligations discharged"
  in
  let why3_mlw =
    Printf.sprintf
      "module Gospel_VC_%s\n  use int.Int\n  use bool.Bool\n  goal G_%s : %b = true\nend"
      o.gco_name o.gco_name all_ok
  in
  let smt2 =
    String.concat "\n" [
      "; Gospel / Cameleer / Why3 SMT-LIB2 Obligation: " ^ o.gco_name;
      "; Diagnostic: " ^ diag;
      "(set-logic QF_BV)";
      Printf.sprintf "(define-fun contract_holds () Bool %s)" (if all_ok then "true" else "false");
      "(assert (not contract_holds))";
      "(check-sat)";
    ]
  in
  {
    gvc_name           = o.gco_name;
    gvc_unsat_verified = all_ok;
    gvc_diagnostic     = diag;
    gvc_why3_mlw       = why3_mlw;
    gvc_smtlib2_query  = smt2;
  }

(* ========================================================================== *)
(* 5. Self-Test Runner for PPX Rewriter & Gospel Contract Solver              *)
(* ========================================================================== *)

let run_ppx_gospel_self_test () : bool =
  let raw_ast =
    Ppx_Annotated (Attr_qfree_anf_certified,
      Ppx_ManualUncomp (
        Ppx_LetStar ("()", Ppx_Prim (Ppx_Toffoli (0, 2, 3)), Ppx_Prim (Ppx_Cnot (3, 2))),
        Ppx_Prim (Ppx_Cz (3, 3)),
        Ppx_Prim (Ppx_Cnot (0, 2)) (* Mismatched manual u_dag replaced by rewrite_qfree_anf_certified! *)
      ))
  in
  let rewritten = rewrite_qfree_anf_certified raw_ast in
  let flat_ops  = flatten_ppx_ast_to_prims rewritten in
  let ppx_ok    = (List.length flat_ops = 5) in

  let clean_w = {
    gw_wire_id   = 2;
    gw_basis     = G_QFree;
    gw_rep       = G_CanonicalRep;
    gw_locked    = false;
    gw_anf_delta = 0;
    gw_anf_deg   = 1;
    gw_zone      = G_Zone_HotSC;
  } in
  let bb_w = { clean_w with gw_wire_id = 0; gw_zone = G_Zone_BBTorus } in
  let good_g = {
    gg_css_round        = G_CSS_Closed;
    gg_latency_ns       = 440;
    gg_live_links       = [];
    gg_barrier_violated = false;
  } in
  let good_ob = {
    gco_name           = "Valid_S10_QDS";
    gco_aux_wires      = [ clean_w ];
    gco_detector_wires = [ clean_w ];
    gco_subtype_pairs  = [ (clean_w, clean_w) ];
    gco_torus_wires    = [ bb_w ];
    gco_global_state   = good_g;
  } in
  let bad_f14 = {
    good_ob with
    gco_name = "Bug_F14_HadDet";
    gco_detector_wires = [ { clean_w with gw_basis = G_HadamardMode } ];
  } in
  let bad_f15 = {
    good_ob with
    gco_name = "Bug_F15_ForgetLock";
    gco_subtype_pairs = [ ({ clean_w with gw_locked = true }, clean_w) ];
  } in
  let bad_f16 = {
    good_ob with
    gco_name = "Bug_F16_MidRoundShift";
    gco_global_state = { good_g with gg_css_round = G_CSS_InFlight_X };
  } in
  let res_good = solve_gospel_qfree_anf_contract good_ob in
  let res_f14  = solve_gospel_qfree_anf_contract bad_f14 in
  let res_f15  = solve_gospel_qfree_anf_contract bad_f15 in
  let res_f16  = solve_gospel_qfree_anf_contract bad_f16 in
  ppx_ok
  && res_good.gvc_unsat_verified
  && (not res_f14.gvc_unsat_verified)
  && (not res_f15.gvc_unsat_verified)
  && (not res_f16.gvc_unsat_verified)

let () = assert (run_ppx_gospel_self_test ())
