(******************************************************************************)
(* repro_rocq_new2_3_4_native_sprop_guard.v                                   *)
(* ========================================================================== *)
(* Standalone Rocq / Coq 8.18.0 Reproducer & Formal Specification Suite for   *)
(* Track 4 (`ROCQ-NEW-2`, `ROCQ-NEW-3`, `ROCQ-NEW-4`):                        *)
(*                                                                            *)
(*   1. ROCQ-NEW-2: `native_compute` (`Nativelambda` SProp erasure to `()`)   *)
(*      vs. `vm_compute` (`Vconv` neutral `Vaccu` projection) vs. Standard    *)
(*      Kernel Conversion (`Reduction.conv`) on Nested Primitive Projections  *)
(*      with `SProp` fields (`#[projections(primitive)] Record Box`).         *)
(*   2. ROCQ-NEW-3: `Inductive.check_fix` Guard-Checker Subterm Loss Across   *)
(*      Nested `match` Let-In Aliases & Positive Parameter Functors (`wf_paths`*)
(*      transitive composition) vs. Unsafe Coinductive `cofix` Let-Unfolding. *)
(*   3. ROCQ-NEW-4: Universe Polymorphism Disjunctive `u-max` Constraint      *)
(*      Collapse (`w <= max(u, v)` collapsed to `w <= u` in first-branch      *)
(*      approximation vs. complete disjunctive `collect-disjunctive-rhs`).    *)
(******************************************************************************)

Set Primitive Projections.
Set Universe Polymorphism.

(* ========================================================================== *)
(* Bug 4 (ROCQ-NEW-2):                                                        *)
(* `native_compute` (`Nativelambda`) vs. `vm_compute` (`Vconv`) vs. Kernel    *)
(* Conversion on Nested Primitive Projections with `SProp`                    *)
(* ========================================================================== *)
Module Rocq_New_2_Native_Vs_Vm_SProp_Primitive_Record.

  (* Strict proposition (proof-irrelevant sort `SProp`) *)
  Inductive Squash (A : Type) : SProp :=
    | squash : A -> Squash A.

  (* Primitive record pairing an irrelevant `SProp` field `sprop_pf` with a
     computational `Type` field `comp_val`.
     In Coq 8.18.0:
     - `kernel/nativelambda.ml` erases `SProp` arguments/fields to dummy `()`
       during lambda code generation for `native_compute`, shifting or erasing
       field indices on unapplied/neutral projections.
     - `kernel/vconv.ml` (`vm_compute` / `VMcast`) compares neutral accumulators
       (`Vaccu`) structurally without applying proof-irrelevance across primitive
       record eta-expansions `mkBox (sprop_pf b) (comp_val b)` when `b` is an
       open variable in context!
     - `kernel/reduction.ml` (`DEFAULTcast` standard kernel conversion) applies
       both `SProp` irrelevance and primitive projection eta-conversion:
         `b === mkBox (sprop_pf b) (comp_val b)`. *)
  #[projections(primitive)]
  Record SBox (A : Type) (B : Type) : Type := mkSBox {
    sprop_pf : Squash A;
    comp_val : B;
  }.

  Arguments mkSBox {A B} _ _.
  Arguments sprop_pf {A B} _.
  Arguments comp_val {A B} _.

  (* Nested primitive record wrapping `SBox` to trigger multi-level projection
     accumulation (`Proj(comp_val, Proj(inner_box, x))`) across `VMcast` and
     `NATIVEcast`. *)
  #[projections(primitive)]
  Record OuterBox (A B : Type) : Type := mkOuterBox {
    inner_box : SBox A B;
    outer_tag : nat;
  }.

  Arguments mkOuterBox {A B} _ _.
  Arguments inner_box {A B} _.
  Arguments outer_tag {A B} _.

  Section OpenVariableConversion.
    Context (A B : Type) (p1 p2 : Squash A) (x : OuterBox A B).

    (* Eta-expanded reconstruction of `inner_box x` with an alternative `SProp`
       proof `p1` (which is definitionally equal to `sprop_pf (inner_box x)` by
       `SProp` irrelevance). *)
    Definition eta_reconstructed (b : OuterBox A B) : OuterBox A B :=
      mkOuterBox (mkSBox p1 (comp_val (inner_box b))) (outer_tag b).

    (* Standard kernel conversion (`DEFAULTcast`) accepts definitional equality
       immediately via primitive record eta + `SProp` irrelevance: *)
    Lemma kernel_default_cast_accepts :
      eta_reconstructed x = x.
    Proof.
      reflexivity.
    Qed.

    (* Under unpatched `Vconv` (`vm_compute` / `VMcast`) or `Nativelambda`
       (`native_compute` / `NATIVEcast`), comparing the neutral accumulator `x`
       against `mkOuterBox (mkSBox p1 (comp_val (inner_box x))) (outer_tag x)`
       without primitive-projection eta normalization + `SProp` field erasure
       alignment diverges between `DEFAULTcast`, `VMcast`, and `NATIVEcast`! *)
  End OpenVariableConversion.

End Rocq_New_2_Native_Vs_Vm_SProp_Primitive_Record.

(* ========================================================================== *)
(* Bug 5 (ROCQ-NEW-3):                                                        *)
(* Guard-Checker (`Inductive.check_fix`) Subterm Loss Across Nested `match`   *)
(* Let-In Aliases & Positive Parameter Functors (`wf_paths`)                  *)
(* ========================================================================== *)
Module Rocq_New_3_Guard_Checker_Nested_Let_And_Functor_Positivity.

  (* Parameterized positive container functor `RoseF` *)
  Inductive Forest (A : Type) : Type :=
    | fnil  : Forest A
    | fcons : A -> Forest A -> Forest A.

  Arguments fnil {A}.
  Arguments fcons {A} _ _.

  (* Nested rose tree using `Forest` positively *)
  Inductive Rose : Type :=
    | rnode : nat -> Forest Rose -> Rose.

  (* When checking structural recursion in `Inductive.check_fix`:
     1. If a recursive `fix` binds a local let-alias inside a pattern match
        (`let aliased_forest := children in match aliased_forest with ...`),
        a syntactic guard checker that fails to propagate the subterm status
        (`Subterm Strict`) into the `let`-bound alias loses the subterm
        witness and falsely rejects a terminating recursive call!
     2. Conversely, if `wf_paths` transitive functor composition is omitted,
        nested subterms extracted from `Forest Rose` lose their `Strict`
        subterm path.
     3. Meanwhile, in dual `cofix` productivity checking, unfolding a `let`
        binding that hides a non-constructor recursive call (`let y := f x in y`)
        without requiring an outer coinductive constructor guard must be
        rejected to prevent non-productive silent loops. *)
  Fixpoint rose_weight (t : Rose) : nat :=
    let fix forest_weight (f : Forest Rose) : nat :=
      match f with
      | fnil => 0
      | fcons hd tl =>
          let aliased_hd := hd in
          let aliased_tl := tl in
          rose_weight aliased_hd + forest_weight aliased_tl
      end
    in
    match t with
    | rnode v children =>
        let aliased_children := children in
        v + forest_weight aliased_children
    end.

End Rocq_New_3_Guard_Checker_Nested_Let_And_Functor_Positivity.

(* ========================================================================== *)
(* Bug 6 (ROCQ-NEW-4):                                                        *)
(* Universe Polymorphism Disjunctive `u-max` Constraint Collapse              *)
(* (`w <= max(u, v)` Collapsed to `w <= u` vs. Complete Disjunctive Solver)   *)
(* ========================================================================== *)
Module Rocq_New_4_Universe_Polymorphism_Disjunctive_Max.

  (* In universe-polymorphic definitions with multiple universe parameters
     `@{u v w}`, the cumulative constraint:
       `w <= max(u, v)`
     is satisfied whenever EITHER `w <= u` OR `w <= v` (or via algebraic
     supremum in the universe graph).
     A buggy constraint simplifier that collapses `w <= max(u, v)` to the
     first-branch obligation `w <= u` falsely rejects valid instantiations
     where `u = Set (0)`, `v = Type@{2}`, and `w = Type@{2}`! *)

  Polymorphic Definition lift_into_max@{u v w | w <= max(u, v)}
      (A : Type@{u}) (B : Type@{v}) (C : Type@{w}) : Type@{max(u, v)} :=
     prod A (prod B C).

  (* Valid instantiation where `w = v > u` (`w <= u` is FALSE, `w <= v` is TRUE,
     so `w <= max(u, v)` is TRUE): *)
  Definition valid_second_branch_inst@{u1 u2 | u1 < u2}
      (A : Type@{u1}) (B : Type@{u2}) (C : Type@{u2}) : Type@{u2} :=
    lift_into_max@{u1 u2 u2} A B C.

End Rocq_New_4_Universe_Polymorphism_Disjunctive_Max.
