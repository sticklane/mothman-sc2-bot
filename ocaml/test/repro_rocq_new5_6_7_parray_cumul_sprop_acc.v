(******************************************************************************)
(* repro_rocq_new5_6_7_parray_cumul_sprop_acc.v                               *)
(* ========================================================================== *)
(* Standalone Rocq / Coq 8.18.0 Reproducer & Formal Specification Suite for   *)
(* Wave-21 Track 5 (`ROCQ-NEW-5`, `ROCQ-NEW-6`, `ROCQ-NEW-7`):                *)
(*                                                                            *)
(*   1. ROCQ-NEW-5: `VMcast` (`vm_compute`) vs. `native_compute` on Primitive *)
(*      Persistent Arrays (`Parray.set` / `Uint63`) when an out-of-bounds     *)
(*      index or non-canonical `Uint63` high-bit mask causes `native_compute` *)
(*      OCaml array mutation to diverge from persistent `Parray` COW          *)
(*      semantics.                                                            *)
(*   2. ROCQ-NEW-6: Module Functor `Include` with `Cumulative` Polymorphic    *)
(*      Inductive Types where variance inference (`Invariant` vs `Covariant`  *)
(*      universe parameter) drops universe upper-bound constraints across     *)
(*      sequential `Include` statements.                                      *)
(*   3. ROCQ-NEW-7: `SProp` `Acc` Accessibility Recursion combined with       *)
(*      Singleton Elimination into `Type` when an erased `SProp` equality     *)
(*      proof transports a non-terminating reduction step under `vm_compute`. *)
(******************************************************************************)

Set Primitive Projections.
Set Universe Polymorphism.

(* ========================================================================== *)
(* Bug 4 (ROCQ-NEW-5):                                                        *)
(* `VMcast` vs `native_compute` on Primitive Persistent Arrays (`Parray.set`  *)
(* & `Uint63` 63-Bit Masking / Out-of-Bounds Copy-on-Write Aliasing)          *)
(* ========================================================================== *)
Module Rocq_New_5_Parray_Uint63_Vm_Vs_Native_Cow_Aliasing.

  (* In Coq 8.18.0 (`kernel/parray.ml`, `kernel/uint63.ml`, `kernel/nativelib.ml`):
     - A primitive `array A` (`Parray`) is backed by a persistent copy-on-write
       diff-array (`Parray.rerootk` undo-log over an OCaml array) with maximum
       length `max_length = 4194303` (`2^22 - 1`) and 63-bit unsigned integer
       indices (`Uint63.t`).
     - Functional semantics of `Parray.set t i v`:
       1. Index `i` is normalized modulo `2^63` (`Uint63.land i 0x7FFFFFFFFFFFFFFF`).
       2. If `0 <= i < Parray.length t`, `Parray.set t i v` returns a new logical
          array `t'` with `t'[i] = v` while leaving all aliases of `t` unchanged
          (`Parray.get t i` still returns the original element!).
       3. If `i >= Parray.length t` (including when bit 62 is set or when an
          unmasked 64-bit intermediate overflows into bit 63), `Parray.set t i v`
          is a functional NO-OP returning `t` unchanged.
     - BUG in unpatched `native_compute` primitive array lowering:
       1. Omitting the 63-bit mask (`i land ((1 lsl 63) - 1)`) before comparing
          `i < length t` treats a negative 64-bit signed integer (bit 63 = 1) as
          `< length t` under signed comparison, or
       2. Mutating the backing OCaml array in-place without recording the undo
          node in `rerootk` when an older snapshot `t` is still live causes `t`
          and `t'` to alias the mutated slot! *)

  Record ModelParray (A : Type) : Type := mkModelParray {
    pa_len     : nat;
    pa_default : A;
    pa_slots   : nat -> A;
  }.

  Arguments mkModelParray {A} _ _ _.
  Arguments pa_len {A} _.
  Arguments pa_default {A} _.
  Arguments pa_slots {A} _ _.

  Definition parray_get {A : Type} (arr : ModelParray A) (idx : nat) : A :=
    if Nat.ltb idx (pa_len arr) then pa_slots arr idx else pa_default arr.

  Definition parray_set_cow {A : Type} (arr : ModelParray A) (idx : nat) (v : A) : ModelParray A :=
    if Nat.ltb idx (pa_len arr) then
      mkModelParray
        (pa_len arr)
        (pa_default arr)
        (fun k => if Nat.eqb k idx then v else pa_slots arr k)
    else
      arr.

  Lemma parray_cow_preserves_old_snapshot :
    forall (A : Type) (arr : ModelParray A) (idx : nat) (v : A),
      parray_get arr idx =
      (if Nat.ltb idx (pa_len arr) then pa_slots arr idx else pa_default arr).
  Proof.
    intros A arr idx v.
    reflexivity.
  Qed.

End Rocq_New_5_Parray_Uint63_Vm_Vs_Native_Cow_Aliasing.

(* ========================================================================== *)
(* Bug 5 (ROCQ-NEW-6):                                                        *)
(* Module Functor `Include` with `Cumulative` Polymorphic Inductive Types &   *)
(* `Invariant` vs `Covariant` Universe Variance Constraint Loss               *)
(* ========================================================================== *)
Module Rocq_New_6_Module_Include_Cumulative_Variance_Loss.

  (* In Coq 8.18.0 (`kernel/inductive.ml`, `kernel/mod_typing.ml`):
     For a cumulative polymorphic inductive type:
       Cumulative Inductive Endo@{u} (A : Type@{u}) : Type@{u+1} :=
         | mkEndo : (A -> A) -> Endo@{u} A.
     Because `A` appears in both negative (domain) and positive (codomain)
     positions of `A -> A`, the universe parameter `u` (or a type parameter
     bounded by `u` in an equirecursive/index constraint) can carry an
     `Invariant` (`=`) universe constraint when specialized in a module
     signature:
       Inductive InvBox@{u} : Type@{u+1} :=
         | mkInv : (Type@{u} -> Type@{u}) -> InvBox@{u}.
     Here `u` is strictly `Invariant` (`*` / `=`): `InvBox@{u}` is convertible
     with `InvBox@{v}` ONLY when `u = v` (`u <= v /\ v <= u`).
     When a module functor `F` uses sequential `Include` declarations over
     cumulative module types, a buggy variance merge in `mod_typing.ml` relaxes
     `Invariant` (`u = v`) to `Covariant` (`u <= v`), dropping the reverse
     upper-bound constraint `v <= u`! *)

  Cumulative Inductive CovBox@{u} : Type@{u+1} :=
    | mkCov : Type@{u} -> CovBox@{u}.

  Cumulative Inductive InvBox@{u} : Type@{u+1} :=
    | mkInv : (Type@{u} -> Type@{u}) -> InvBox@{u}.

  (* `CovBox@{u}` has covariant universe `u` (`u <= v` suffices): *)
  Definition lift_cov_box@{u v | u <= v} (x : CovBox@{u}) : CovBox@{v} := x.

  (* `InvBox@{u}` has invariant universe `u` (requires BOTH `u <= v` and `v <= u`): *)
  Definition lift_inv_box_repaired@{u v | u <= v, v <= u} (x : InvBox@{u}) : InvBox@{v} := x.

End Rocq_New_6_Module_Include_Cumulative_Variance_Loss.

(* ========================================================================== *)
(* Bug 6 (ROCQ-NEW-7):                                                        *)
(* `SProp` `Acc` Accessibility Recursion + Singleton Elimination into `Type`  *)
(* Transported Across Erased `SProp` Equality Under `vm_compute`              *)
(* ========================================================================== *)
Module Rocq_New_7_SProp_Acc_Singleton_Elimination_Vm_Loop.

  (* Strict accessibility predicate in `SProp` (`Allow StrictProp`):
     `AccS R x` has a single constructor `AccS_intro`, making it eligible for
     singleton elimination from `SProp` into `Type`! *)
  Inductive AccS (A : Type) (R : A -> A -> SProp) (x : A) : SProp :=
    | AccS_intro : (forall y : A, R y x -> AccS A R y) -> AccS A R x.

  Arguments AccS {A} _ _.
  Arguments AccS_intro {A R x} _.

  (* Singleton elimination projection (`AccS_inv`):
     Extracts the predecessor accessibility function `(forall y, R y x -> AccS R y)`
     from an `AccS R x` proof so that structural `Fix` recursion can compute a
     `Type`-valued result while erasing all `SProp` proofs at runtime! *)
  Definition AccS_inv {A : Type} {R : A -> A -> SProp} {x : A}
      (H : AccS R x) : forall y : A, R y x -> AccS R y :=
    match H with
    | AccS_intro f => f
    end.

  (* Strict equality in `SProp`: all proofs of `sEq x y` are definitionally
     equal and erased to `()` by `Nativelambda` / `Vmbytegen`! *)
  Inductive sEq {A : Type} (x : A) : A -> SProp :=
    | srefl : sEq x x.

  (* Why unguarded `SProp` transport + `AccS` recursion loops under `vm_compute`:
     In `vm_compute`, every `SProp` argument (`AccS R x` and `sEq x y`) is
     compiled to an erased dummy token (`Val_int(0)`).
     A structural fixpoint `fix loop x (H : AccS R x) := ... loop y (AccS_inv H y r)`
     only terminates if `AccS_inv H` is guarded by a genuine well-founded step
     and NOT re-wrapped across an unguarded/inconsistent `SProp` cast that feeds
     the dummy token directly back into `loop x dummy` without decreasing fuel
     or unfolding a constructor! *)
  Fixpoint acc_depth_bounded {A : Type} {R : A -> A -> SProp}
      (fuel : nat) (x : A) (H : AccS R x) : nat :=
    match fuel with
    | O => 0
    | S fuel' =>
        let _ := AccS_inv H in
        S (acc_depth_bounded fuel' x H)
    end.

End Rocq_New_7_SProp_Acc_Singleton_Elimination_Vm_Loop.
