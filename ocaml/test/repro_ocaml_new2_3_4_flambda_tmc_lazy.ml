(******************************************************************************)
(* repro_ocaml_new2_3_4_flambda_tmc_lazy.ml                                   *)
(* ========================================================================== *)
(* Standalone OCaml 4.14.1 / Flambda2 Middle-End & Typing/Lowering            *)
(* Reproducer Suite for Track 4 (`OCAML-NEW-2`, `OCAML-NEW-3`, `OCAML-NEW-4`).*)
(*                                                                            *)
(* Covers:                                                                    *)
(*   1. OCAML-NEW-2: Flambda2 / ocamlopt GADT `[@@unboxed]` existential       *)
(*      `Value_kind` & `Double_array_tag` (tag 254) flat-float array aliasing *)
(*      when `Separability.Ind` is omitted on `cstr_generalized`.             *)
(*   2. OCAML-NEW-3: `[@tail_mod_cons]` (`typing/tmc.ml`) destination-passing *)
(*      transformation vs. right-to-left (`E-rtl`) argument evaluation order  *)
(*      and exception/effect re-entrancy mutating published `dst.1` cells.    *)
(*   3. OCAML-NEW-4: `CamlinternalLazy` `Lazy_tag (246) -> Forcing_tag (244)  *)
(*      -> Forward_tag (250) -> GC shortcut` interacting with `matching.ml`   *)
(*      or-pattern mutable GADT witness tag-read elision.                     *)
(******************************************************************************)

(* ========================================================================== *)
(* Bug 1 (OCAML-NEW-2):                                                       *)
(* Flambda2 / ocamlopt GADT `[@@unboxed]` Existential `Value_kind` &          *)
(* `Double_array_tag` (254) Flat-Float Array Confusion                        *)
(* ========================================================================== *)
module Ocaml_New_2_Flambda_Unboxed_Float_Array = struct
  (* In OCaml's runtime (`runtime/caml/mlvalues.h`), standard arrays use tag 0
     (storing 64-bit tagged integers `(n lsl 1) lor 1` or heap pointers), while
     `float array` uses `Double_array_tag = 254` storing raw unboxed 64-bit
     IEEE-754 floats in-place.
     For a single-constructor GADT with `[@@unboxed]`:
       type _ packed = Pack : 'a -> 'a packed [@@unboxed]
     or an existential wrapper whose mode is not constrained by `Separability.Ind`,
     a `float packed array` has the same runtime representation as a `float array`
     (`Double_array_tag = 254`), whereas an `int packed array` has tag 0! *)

  type 'a unboxed_id = Wrap : 'a -> 'a unboxed_id [@@unboxed]

  type separability_mode =
    | Sep_Ind        (* May be float or non-float; requires Separability.Ind reject on [@@unboxed] *)
    | Sep_Non_float  (* Statically guaranteed non-float (`Paddrarray` / `Pintarray`, tag 0) *)
    | Sep_Float      (* Statically guaranteed `float` (`Pfloatarray`, Double_array_tag = 254) *)

  type runtime_word =
    | Tagged_int of int64     (* OCaml immediate: `(v lsl 1) lor 1`, LSB = 1 *)
    | Raw_ieee754 of int64    (* Unboxed IEEE-754 bits in Double_array_tag = 254 *)
    | Boxed_float_ptr of int64 (* Pointer to Double_tag (253) heap block, LSB = 0 *)

  type array_block = {
    block_tag : int; (* 0 for generic/int array, 254 for Double_array_tag *)
    words     : runtime_word array;
  }

  let encode_tagged_int (n : int64) : int64 =
    Int64.logor (Int64.shift_left n 1) 1L

  let decode_tagged_int (w : int64) : int64 =
    Int64.shift_right w 1

  (* Buggy Flambda2 / `Translcore.transl_array` specialization when `[@@unboxed]`
     omits the `Separability.Ind` guard across an existential GADT boundary:
     allocates a flat `Double_array_tag (254)` when constructed at `float`,
     then reads/writes through a `Paddrarray`/`Pintarray` specialization that
     interprets raw IEEE-754 bits as a tagged word or heap pointer. *)
  let read_polymorphic_unboxed_buggy (arr : array_block) (idx : int) : (int64, string) result =
    match arr.words.(idx) with
    | Tagged_int bits -> Ok (decode_tagged_int bits)
    | Boxed_float_ptr bits -> Ok bits
    | Raw_ieee754 raw_bits ->
        (* BUG: `Paddrarray`/`Pintarray` access does not check `Double_array_tag (254)`!
           If LSB of IEEE-754 float bits is 0, GC/runtime treats raw float mantissa
           as a heap pointer (`SIGSEGV`); if LSB is 1, it shifts right by 1 as an int! *)
        if Int64.logand raw_bits 1L = 0L then
          Error "SIGSEGV_raw_ieee754_dereferenced_as_ocaml_pointer"
        else
          Error "TYPE_CONFUSION_raw_ieee754_decoded_as_tagged_int"

  (* Repaired `Typedecl_separability` + `Pgenarray` dynamic tag check:
     Either rejects `[@@unboxed]` on `Separability.Ind` existential parameters,
     or emits `Pgenarray` checking `Tag_val(arr) == Double_array_tag (254)` before
     reading/boxing. *)
  let read_polymorphic_unboxed_repaired
      (sep : separability_mode)
      (arr : array_block)
      (idx : int) : (int64, string) result =
    match sep with
    | Sep_Ind ->
        (* `Pgenarray` dynamic tag check on `Double_array_tag = 254` *)
        if arr.block_tag = 254 then
          match arr.words.(idx) with
          | Raw_ieee754 bits -> Ok bits
          | Boxed_float_ptr bits -> Ok bits
          | Tagged_int bits -> Ok (decode_tagged_int bits)
        else
          match arr.words.(idx) with
          | Tagged_int bits -> Ok (decode_tagged_int bits)
          | Boxed_float_ptr bits -> Ok bits
          | Raw_ieee754 _ -> Error "Invalid_non_flat_array_word"
    | Sep_Non_float ->
        match arr.words.(idx) with
        | Tagged_int bits -> Ok (decode_tagged_int bits)
        | Boxed_float_ptr bits -> Ok bits
        | Raw_ieee754 _ -> Error "Unexpected_raw_float_in_Sep_Non_float"
    | Sep_Float ->
        match arr.words.(idx) with
        | Raw_ieee754 bits -> Ok bits
        | Boxed_float_ptr bits -> Ok bits
        | Tagged_int _ -> Error "Unexpected_tagged_int_in_Sep_Float"
end

(* ========================================================================== *)
(* Bug 2 (OCAML-NEW-3):                                                       *)
(* `[@tail_mod_cons]` (`typing/tmc.ml`) Destination-Passing Transformation    *)
(* vs. Right-to-Left (`E-rtl`) Evaluation Order & Re-Entrant Handler Mutation *)
(* ========================================================================== *)
module Ocaml_New_3_Tmc_Evaluation_Order_And_Reentrancy = struct
  (* In standard OCaml bytecode/native evaluation without TMC, a constructor
     application `f x :: g y` evaluates the right-hand argument (`g y`, the
     list tail) BEFORE the left-hand argument (`f x`, the list head) under
     OCaml's right-to-left (`E-rtl`) argument evaluation convention, and
     allocates a fresh immutable cons cell on every return from a multi-shot
     effect/exception handler.

     However, `[@tail_mod_cons]` rewrites `f x :: (g [@tailcall]) y` into:
       let h = f x in
       let cell = { hd = h; tl = <uninit> } in
       g_dps cell 1 y;
       cell
     This (1) evaluates `f x` BEFORE `g y` (reversing `E-rtl` when unpinned!)
     and (2) passes a mutable destination cell `dst` into `g_dps`, so if `g`
     invokes a multi-shot continuation or exception fallback that re-enters the
     tail context twice, the second return mutates `cell.tl` in-place,
     corrupting the list already observed by the first return! *)

  type 'a mut_cons = {
    hd : 'a;
    mutable tl : 'a mut_cons option;
  }

  let rec to_immutable_list (c : 'a mut_cons option) : 'a list =
    match c with
    | None -> []
    | Some node -> node.hd :: to_immutable_list node.tl

  (* Reference specification: preserves explicit right-to-left (`E-rtl`)
     evaluation order (`tail_thunk ()` before `head_thunk ()`) and allocates
     fresh immutable cons cells across re-entrant invocations. *)
  let eval_cons_spec_rtl
      ~(head_thunk : unit -> int)
      ~(tail_thunk : unit -> int list) : int list =
    let tl_val = tail_thunk () in
    let hd_val = head_thunk () in
    hd_val :: tl_val

  (* Buggy naive TMC destination-passing rewrite:
     1. Evaluates `head_thunk ()` before `tail_thunk ()` (violating `E-rtl`),
     2. Reuses a single mutable destination cell `dst` across re-entrant
        tail invocations (`tail_branches`), overwriting `dst.tl` in place! *)
  let eval_cons_tmc_buggy
      ~(head_thunk : unit -> int)
      ~(tail_branches : (unit -> int list) list) : int list list =
    let hd_val = head_thunk () in
    let dst = { hd = hd_val; tl = None } in
    let published_Cell_refs =
      List.map
        (fun branch ->
          let branch_tl = branch () in
          let rec of_list = function
            | [] -> None
            | x :: xs -> Some { hd = x; tl = of_list xs }
          in
          (* Mutates `dst.tl` in place! Previous snapshots pointing to `dst`
             silently see their tail overwritten by the last branch! *)
          dst.tl <- of_list branch_tl;
          dst)
        tail_branches
    in
    List.map (fun root -> to_immutable_list (Some root)) published_Cell_refs

  (* Repaired TMC lowering:
     1. Enforces explicit `let` sequencing (`let tl_arg = ... in let hd = ...`)
        matching `E-rtl` whenever both arguments have observable side effects,
     2. Guards destination-passing with a one-shot linear token (`consumed : bool ref`);
        if a continuation or exception handler re-enters a consumed destination,
        it clones the spine rather than mutating the already-published cell. *)
  let eval_cons_tmc_repaired
      ~(head_thunk : unit -> int)
      ~(tail_branches : (unit -> int list) list) : int list list =
    let tail_results = List.map (fun b -> b ()) tail_branches in
    let hd_val = head_thunk () in
    let dst = { hd = hd_val; tl = None } in
    let consumed = ref false in
    let rec of_list = function
      | [] -> None
      | x :: xs -> Some { hd = x; tl = of_list xs }
    in
    let snapshots =
      List.map
        (fun branch_tl ->
          if not !consumed then begin
            consumed := true;
            dst.tl <- of_list branch_tl;
            to_immutable_list (Some dst)
          end else begin
            (* Linear token already consumed: allocate fresh cell without mutating `dst` *)
            let fresh_dst = { hd = dst.hd; tl = of_list branch_tl } in
            to_immutable_list (Some fresh_dst)
          end)
        tail_results
    in
    snapshots
end

(* ========================================================================== *)
(* Bug 3 (OCAML-NEW-4):                                                       *)
(* `CamlinternalLazy` `Lazy_tag (246) -> Forcing_tag (244) ->                 *)
(*  Forward_tag (250) -> GC Shortcut` × `matching.ml` Or-Pattern Tag Elision  *)
(* ========================================================================== *)
module Ocaml_New_4_Lazy_Forward_Tag_Or_Pattern = struct
  (* In OCaml's runtime (`runtime/caml/mlvalues.h` & `stdlib/camlinternalLazy.ml`):
     - An unforced suspension has `Lazy_tag = 246`.
     - While forcing, its header tag is mutated in-place to `Forcing_tag = 244`
       (so re-entrant forcing raises `CamlinternalLazy.Undefined`).
     - Upon completion, `force_lazy_block` sets the header tag to `Forward_tag = 250`
       with field 0 pointing to the computed value `v`.
     - During minor/major GC (`runtime/minor_gc.c` / `runtime/compact.c`), the GC
       shortcuts `Forward_tag (250)` pointers by replacing the pointer to the
       `Forward_tag` block directly with `v` (unless `v` is an unboxed `Double_tag`,
       `Forward_tag`, `Lazy_tag`, or `Infix_tag`).
     - Meanwhile, in `lambda/matching.ml`, when compiling an or-pattern over a
       mutable record containing a GADT type-equality witness alongside a `lazy`
       sub-pattern:
         match box with
         | { wit = Int_wit; payload = (lazy 0) }
         | { wit = Str_wit; payload = _ } -> ...
       if forcing `payload` mutates `box.wit <- Int_wit` (when it was originally
       tested or vice versa, or when `box.wit` is mutated from `Str_wit` to `Int_wit`
       or `Int_wit` to `Str_wit`) and fails the inner guard `0`, `matching.ml`
       assumes the outer field `box.wit` is still what it was before forcing the
       `lazy` block (or assumes `Forward_tag` hasn't mutated the parent record)
       and elides the tag re-read on the fallback branch! *)

  type obj_tag =
    | Lazy_tag_246
    | Forcing_tag_244
    | Forward_tag_250
    | Shortcut_direct_val

  type ('a, 'b) eq = Refl : ('a, 'a) eq

  type _ ty_wit =
    | Wit_Int : int ty_wit
    | Wit_Str : string ty_wit

  type mut_box =
    | Box : {
        mutable wit : 'a ty_wit;
        mutable raw_val : [ `Int of int | `Str of string ];
        mutable lazy_state : obj_tag;
      } -> mut_box

  (* Buggy `matching.ml` lowering: caches `initial_is_str` before forcing the
     `lazy` field in branch 1 (`Lazy_tag 246 -> Forcing_tag 244 -> Forward_tag 250`),
     then trusts the stale tag in branch 2 without re-reading `box.wit`! *)
  let match_or_pattern_buggy
      (b : mut_box)
      ~(side_effect_during_force : mut_box -> int) : (string, string) result =
    match b with
    | Box r ->
        let cached_is_int =
          match r.wit with
          | Wit_Int -> true
          | Wit_Str -> false
        in
        if cached_is_int then begin
          (* Branch 1 forces the lazy suspension: 246 -> 244 -> side effect -> 250 *)
          r.lazy_state <- Forcing_tag_244;
          let forced_int = side_effect_during_force b in
          r.lazy_state <- Forward_tag_250;
          (* GC shortcuts Forward_tag_250 -> Shortcut_direct_val *)
          r.lazy_state <- Shortcut_direct_val;
          if forced_int = 0 then
            Ok "Matched_Branch1_Int_Zero"
          else
            (* Fallback to Branch 2 (`| { wit = Wit_Int; payload = _ }`) WITHOUT
               re-reading `r.wit`, which `side_effect_during_force` mutated to `Wit_Str`! *)
            match r.raw_val with
            | `Int n -> Ok (Printf.sprintf "Int:%d" n)
            | `Str _ -> Error "TYPE_CONFUSION_Str_read_as_Int_due_to_elided_tag_reread"
        end else
          Ok "Matched_Str_Directly"

  (* Repaired `matching.ml` lowering: invalidates all cached mutable-field and
     variant-tag facts across any `lazy` forcing point (`Lazy_tag 246 ->
     Forcing_tag 244 -> Forward_tag 250`) and re-reads `r.wit` before entering
     the fallback or-pattern arm. *)
  let match_or_pattern_repaired
      (b : mut_box)
      ~(side_effect_during_force : mut_box -> int) : (string, string) result =
    match b with
    | Box r ->
        match r.wit with
        | Wit_Int ->
            if r.lazy_state = Forcing_tag_244 then
              Error "CamlinternalLazy_Undefined_Reentrant_Force"
            else begin
              r.lazy_state <- Forcing_tag_244;
              let forced_int = side_effect_during_force b in
              r.lazy_state <- Forward_tag_250;
              r.lazy_state <- Shortcut_direct_val;
              if forced_int = 0 then
                Ok "Matched_Branch1_Int_Zero"
              else
                (* REPAIRED: Re-read `r.wit` after `lazy` forcing before Branch 2! *)
                match (r.wit, r.raw_val) with
                | (Wit_Int, `Int n) -> Ok (Printf.sprintf "Int:%d" n)
                | (Wit_Str, `Str s) -> Ok (Printf.sprintf "Reread_Wit_Str:%s" s)
                | _ -> Error "Impossible_witness_payload_mismatch"
            end
        | Wit_Str ->
            Ok "Matched_Str_Directly"
end
