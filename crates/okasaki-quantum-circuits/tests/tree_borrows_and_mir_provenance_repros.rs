//! Standalone Rust integration tests and formal operational semantics reproducers for:
//! - `RUST-NEW-1`: `Tree Borrows` Two-Phase Borrow `ReservedIM` vs. `ReservedFrz` Activation
//!                 + `UnsafeCell` (`!Freeze`) Interior Mutability vs. LLVM `noalias` Miscompilation
//! - `RUST-NEW-2`: Rust MIR `GVN` / `InstSimplify` Pointer-Provenance Conflation on `addr_of!`
//!                 / Int-to-Ptr Round-Trip `expose_provenance`
//! - `RUST-NEW-3`: Rust Enum Niche Layout Optimization × `MaybeUninit` / Transmute Padding
//!                 Byte Clobber

use okasaki_quantum_circuits::*;

// ============================================================================
// 1. RUST-NEW-1: Tree Borrows Two-Phase Borrow (`ReservedIM` vs `ReservedFrz`)
//    + `UnsafeCell` (`!Freeze`) vs. LLVM `noalias` GVN Load Hoisting
// ============================================================================

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum TbPermission {
    ReservedFrz,
    ReservedIm,
    Active,
    Frozen,
    Disabled,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct TwoPhaseBorrowTrial {
    pub has_unsafe_cell: bool,
    pub foreign_read_before_act: bool,
    pub child_im_write_before_act: bool,
    pub initial_val: i64,
    pub im_written_val: i64,
}

/// Buggy `Tree Borrows` + LLVM codegen model that treats all two-phase `Reserved`
/// borrows as `noalias`-eligible even when `T` contains an `UnsafeCell` (`!Freeze`).
/// When `child_im_write_before_act` mutates the location before two-phase activation,
/// LLVM GVN hoists a coexisting shared read across the write, returning stale `initial_val`!
pub fn eval_buggy_tree_borrows_two_phase_noalias(trial: TwoPhaseBorrowTrial) -> (i64, i64, bool) {
    let true_mem_after = if trial.child_im_write_before_act {
        trial.im_written_val
    } else {
        trial.initial_val
    };
    // Buggy compiler emits LLVM `noalias` unconditionally on Reserved two-phase borrow:
    let buggy_emits_noalias = true;
    let gvn_hoisted_read = if buggy_emits_noalias && trial.foreign_read_before_act {
        trial.initial_val
    } else {
        true_mem_after
    };
    let miscompiled = gvn_hoisted_read != true_mem_after;
    (gvn_hoisted_read, true_mem_after, miscompiled)
}

/// Sound guarded `Tree Borrows` (`#:freeze?` discipline distinguishing `ReservedFrz`
/// from `ReservedIm`): suppresses LLVM `noalias` whenever `has_unsafe_cell` (`!Freeze`)
/// is true, preventing LLVM GVN from hoisting stale reads across interior-mutable writes.
pub fn eval_guarded_tree_borrows_two_phase_noalias(
    trial: TwoPhaseBorrowTrial,
) -> (TbPermission, i64, i64, bool) {
    let init_perm = if trial.has_unsafe_cell {
        TbPermission::ReservedIm
    } else {
        TbPermission::ReservedFrz
    };
    let emits_noalias = matches!(init_perm, TbPermission::ReservedFrz);
    let true_mem_after = if trial.child_im_write_before_act && trial.has_unsafe_cell {
        trial.im_written_val
    } else {
        trial.initial_val
    };
    let observed_read = if emits_noalias && trial.foreign_read_before_act {
        trial.initial_val
    } else {
        true_mem_after
    };
    let miscompiled = observed_read != true_mem_after;
    (init_perm, observed_read, true_mem_after, miscompiled)
}

#[test]
fn test_rust_new_1_tree_borrows_reserved_im_vs_frz_noalias_20000_trials() {
    let mut buggy_miscompilations = 0usize;
    let mut guarded_miscompilations = 0usize;

    for i in 0..20_000usize {
        let has_unsafe_cell = (i % 2) == 0;
        let foreign_read_before_act = (i % 3) != 0;
        let child_im_write_before_act = has_unsafe_cell && ((i % 5) != 0);
        let initial_val = (i as i64) * 7 + 3;
        let im_written_val = initial_val + 99;

        let trial = TwoPhaseBorrowTrial {
            has_unsafe_cell,
            foreign_read_before_act,
            child_im_write_before_act,
            initial_val,
            im_written_val,
        };

        let (_, _, bug_mis) = eval_buggy_tree_borrows_two_phase_noalias(trial);
        if bug_mis {
            buggy_miscompilations += 1;
        }

        let (perm, obs, truth, guard_mis) = eval_guarded_tree_borrows_two_phase_noalias(trial);
        assert_eq!(obs, truth);
        assert!(!guard_mis);
        if has_unsafe_cell {
            assert_eq!(perm, TbPermission::ReservedIm);
        } else {
            assert_eq!(perm, TbPermission::ReservedFrz);
        }
        if guard_mis {
            guarded_miscompilations += 1;
        }
    }

    assert!(buggy_miscompilations > 0);
    assert_eq!(guarded_miscompilations, 0);
}

// ============================================================================
// 2. RUST-NEW-2: Rust MIR `GVN` / `InstSimplify` Pointer-Provenance Conflation
//    on `addr_of!` / Int-to-Ptr Round-Trip `expose_provenance`
// ============================================================================

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct ProvenancePtr {
    pub alloc_id: u32,
    pub base_addr: usize,
    pub offset: usize,
    pub alloc_len: usize,
}

impl ProvenancePtr {
    pub const fn runtime_addr(&self) -> usize {
        self.base_addr + self.offset
    }

    pub const fn can_deref_write(&self, write_len: usize) -> bool {
        self.offset + write_len <= self.alloc_len
    }
}

/// Buggy MIR `GVN` pass: replaces `p2` with `p1` inside a branch guarded by
/// `p1.runtime_addr() == p2.runtime_addr()`, ignoring `p1.alloc_id != p2.alloc_id`.
/// When `p1` is one-past-the-end of allocation `A` (`offset == alloc_len`) and `p2`
/// is the start of adjacent allocation `B` (`offset == 0`), writing through the
/// GVN-substituted pointer `p1` triggers an out-of-bounds UB write on `alloc_id_A`!
pub fn eval_buggy_mir_gvn_pointer_subst(p1: ProvenancePtr, p2: ProvenancePtr) -> ProvenancePtr {
    if p1.runtime_addr() == p2.runtime_addr() {
        p1 // BUG: conflates provenance of p2 with p1!
    } else {
        p2
    }
}

/// Sound provenance-aware MIR `GVN` pass (`RUST-NEW-2`): substitutes `p1` for `p2`
/// iff both runtime integer address AND allocation provenance `alloc_id` match.
pub fn eval_guarded_mir_gvn_pointer_subst(p1: ProvenancePtr, p2: ProvenancePtr) -> ProvenancePtr {
    if p1.runtime_addr() == p2.runtime_addr() && p1.alloc_id == p2.alloc_id {
        p1
    } else {
        p2
    }
}

#[test]
fn test_rust_new_2_mir_gvn_pointer_provenance_conflation() {
    // Allocation A at [0x1000, 0x1010), p1 = one-past-end (0x1010, alloc_id = 1)
    let p1_one_past_end_a = ProvenancePtr {
        alloc_id: 1,
        base_addr: 0x1000,
        offset: 16,
        alloc_len: 16,
    };
    // Adjacent allocation B at [0x1010, 0x1020), p2 = start of B (0x1010, alloc_id = 2)
    let p2_start_of_b = ProvenancePtr {
        alloc_id: 2,
        base_addr: 0x1010,
        offset: 0,
        alloc_len: 16,
    };

    assert_eq!(p1_one_past_end_a.runtime_addr(), p2_start_of_b.runtime_addr());
    assert!(!p1_one_past_end_a.can_deref_write(4));
    assert!(p2_start_of_b.can_deref_write(4));

    let buggy_target = eval_buggy_mir_gvn_pointer_subst(p1_one_past_end_a, p2_start_of_b);
    assert!(!buggy_target.can_deref_write(4)); // UB: out-of-bounds write on alloc A!

    let guarded_target = eval_guarded_mir_gvn_pointer_subst(p1_one_past_end_a, p2_start_of_b);
    assert_eq!(guarded_target.alloc_id, 2);
    assert!(guarded_target.can_deref_write(4)); // Sound: preserves alloc B provenance!
}

// ============================================================================
// 3. RUST-NEW-3: Rust Enum Niche Layout Optimization × `MaybeUninit` /
//    Transmute Padding Byte Clobber
// ============================================================================

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum ShadowByte {
    Init(u8),
    Uninit,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct NicheEnumShadowLayout {
    pub payload_b0: ShadowByte,
    pub pad_or_niche_b1: ShadowByte,
    pub payload_b2: ShadowByte,
    pub pad_b3: ShadowByte,
}

/// Buggy typed copy of the inner payload struct: resets struct padding byte `b1`
/// to `ShadowByte::Uninit`, clobbering an overlapping enum niche discriminant stored
/// in `b1` (e.g., `NonZeroU8` niche tag `0` or custom niche tag `2..=255`).
pub fn eval_buggy_typed_payload_copy(src: NicheEnumShadowLayout) -> NicheEnumShadowLayout {
    NicheEnumShadowLayout {
        payload_b0: src.payload_b0,
        pad_or_niche_b1: ShadowByte::Uninit, // BUG: typed copy drops padding/niche byte!
        payload_b2: src.payload_b2,
        pad_b3: ShadowByte::Uninit,
    }
}

/// Sound `MaybeUninit` byte-preserving copy (`RUST-NEW-3`): copies all `ShadowByte`
/// lanes verbatim without stripping niche discriminant tags or tainting initialized bytes.
pub fn eval_guarded_maybe_uninit_byte_copy(src: NicheEnumShadowLayout) -> NicheEnumShadowLayout {
    src
}

#[test]
fn test_rust_new_3_enum_niche_layout_maybe_uninit_padding_preservation() {
    let mut qc = QCircuit::new();
    let q0 = qc.alloc_qubit(true);
    let q1 = qc.alloc_qubit(false);
    qc.cx(q0, q1);
    assert!(qc.read_bit(q1));
    qc.cx(q0, q1);
    qc.assert_ancillas_clean();

    let niche_packed = NicheEnumShadowLayout {
        payload_b0: ShadowByte::Init(0x42),
        pad_or_niche_b1: ShadowByte::Init(0x00), // Active niche discriminant tag!
        payload_b2: ShadowByte::Init(0x99),
        pad_b3: ShadowByte::Init(0xAA),
    };

    let after_buggy = eval_buggy_typed_payload_copy(niche_packed);
    assert_eq!(after_buggy.pad_or_niche_b1, ShadowByte::Uninit); // Clobbered!

    let after_guarded = eval_guarded_maybe_uninit_byte_copy(niche_packed);
    assert_eq!(after_guarded, niche_packed);
    assert_eq!(after_guarded.pad_or_niche_b1, ShadowByte::Init(0x00));
}
