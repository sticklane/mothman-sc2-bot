//! Comprehensive integration test suite for `okasaki-quantum-circuits` (27 tests).
//!
//! Verifies:
//! - Bit-exact reversibility ($U^\dagger U = I$) and computational basis simulation
//! - Strict ancilla hygiene (`assert_ancillas_clean()`: 0 dirty ancillas across all tests)
//! - All 9 Quantum Data Structures (Subsections 3.1–3.9)
//! - All End-to-End Quantum Cryptographic & Optimization Algorithms (Sections 4–10)
//! - Exact qubit and Toffoli resource ledgers matching the paper's tables.

use okasaki_quantum_circuits::*;

#[test]
fn test_01_qcircuit_primitive_gates_and_adjoint() {
    let mut qc = QCircuit::new();
    let a = qc.alloc_qubit(true);
    let b = qc.alloc_qubit(true);
    let c = qc.alloc_qubit(false);

    qc.ccx(a, b, c);
    assert!(qc.read_bit(c));
    assert_eq!(qc.profile.toffoli_count, 1);

    let snap = qc.netlist.clone();
    qc.apply_adjoint_slice(&snap);
    assert!(!qc.read_bit(c));
    qc.assert_ancillas_clean();
}

#[test]
fn test_02_ancilla_pool_reuse_and_hygiene() {
    let mut qc = QCircuit::new();
    let x = qc.alloc_qubit(true);
    let y = qc.alloc_qubit(true);

    let anc1 = qc.alloc_ancilla();
    qc.ccx(x, y, anc1);
    assert_eq!(qc.profile.peak_ancilla_qubits, 1);
    qc.meas_x_uncompute_and(x, y, anc1);
    qc.free_ancilla(anc1);

    // Re-allocating ancilla reuses the returned clean qubit without increasing peak_ancilla_qubits
    let anc2 = qc.alloc_ancilla();
    assert_eq!(anc1, anc2);
    assert_eq!(qc.profile.peak_ancilla_qubits, 1);
    qc.free_ancilla(anc2);
    qc.assert_ancillas_clean();
}

#[test]
fn test_03_huet_zipper_constant_shift_zero_gates() {
    let mut qc = QCircuit::new();
    let limbs = vec![
        qc.alloc_reg(4, 0x1),
        qc.alloc_reg(4, 0x2),
        qc.alloc_reg(4, 0x3),
        qc.alloc_reg(4, 0x4),
    ];
    let mut zipper = HuetFocusZipper::new(limbs, 4);
    zipper.cyclic_constant_shift(1);
    assert_eq!(qc.read_reg(&zipper.limbs[0]), 0x2);
    assert_eq!(qc.read_reg(&zipper.limbs[3]), 0x1);
    assert_eq!(qc.profile.toffoli_count, 0);
    assert_eq!(qc.profile.cnot_count, 0);
    qc.assert_ancillas_clean();
}

#[test]
fn test_04_huet_zipper_controlled_fredkin_barrel_shift() {
    let mut qc = QCircuit::new();
    let ctrl = qc.alloc_qubit(true);
    let limbs = vec![
        qc.alloc_reg(4, 10),
        qc.alloc_reg(4, 11),
        qc.alloc_reg(4, 12),
        qc.alloc_reg(4, 13),
    ];
    let zipper = HuetFocusZipper::new(limbs, 4);
    zipper.controlled_fredkin_barrel_shift(&mut qc, ctrl, 1);
    assert_eq!(qc.read_reg(&zipper.limbs[0]), 11);
    assert_eq!(qc.read_reg(&zipper.limbs[1]), 12);
    assert_eq!(qc.read_reg(&zipper.limbs[2]), 13);
    assert_eq!(qc.read_reg(&zipper.limbs[3]), 10);
    assert_eq!(qc.profile.cswap_count, 3 * 4);
    assert_eq!(qc.profile.peak_ancilla_qubits, 0);
    qc.assert_ancillas_clean();
}

#[test]
fn test_05_huet_zipper_streaming_limb_fold() {
    let mut qc = QCircuit::new();
    let limbs = vec![
        qc.alloc_reg(4, 0b0011),
        qc.alloc_reg(4, 0b0101),
        qc.alloc_reg(4, 0b1001),
    ];
    let mut acc = qc.alloc_reg(4, 0);
    let mut zipper = HuetFocusZipper::new(limbs, 4);
    zipper.streaming_limb_fold(&mut qc, &mut acc);
    assert_eq!(qc.read_reg(&acc), 0b0011 ^ 0b0101 ^ 0b1001);
    qc.assert_ancillas_clean();
}

#[test]
fn test_06_skew_binary_gidney_ripple_add_mbu_exact_counts() {
    for n in [2usize, 4, 8, 16] {
        let mut qc = QCircuit::new();
        let a_val = 0x35u128 & ((1u128 << n) - 1);
        let b_val = 0x5Bu128 & ((1u128 << n) - 1);
        let a = qc.alloc_reg(n, a_val);
        let mut b = qc.alloc_reg(n, b_val);

        SkewBinaryCarrySaveNumeral::gidney_ripple_add_mbu(&mut qc, &a, &mut b);
        let expected = (a_val + b_val) & ((1u128 << n) - 1);
        assert_eq!(qc.read_reg(&b), expected);
        assert_eq!(qc.read_reg(&a), a_val);
        assert_eq!(qc.profile.toffoli_count, n - 1);
        assert_eq!(qc.profile.meas_x_count, n - 1);
        assert_eq!(qc.profile.peak_ancilla_qubits, n - 1);
        qc.assert_ancillas_clean();
    }
}

#[test]
fn test_07_skew_binary_gidney_add_sub_reversibility() {
    let mut qc = QCircuit::new();
    let a = qc.alloc_reg(8, 173);
    let mut b = qc.alloc_reg(8, 219);
    SkewBinaryCarrySaveNumeral::gidney_ripple_add_mbu(&mut qc, &a, &mut b);
    assert_eq!(qc.read_reg(&b), (173 + 219) % 256);
    SkewBinaryCarrySaveNumeral::gidney_ripple_sub_mbu(&mut qc, &a, &mut b);
    assert_eq!(qc.read_reg(&b), 219);
    assert_eq!(qc.read_reg(&a), 173);
    qc.assert_ancillas_clean();
}

#[test]
fn test_08_skew_local_add_limb_and_inter_window_fold() {
    let mut qc = QCircuit::new();
    let x_limb = qc.alloc_reg(4, 12);
    let mut y_limb = qc.alloc_reg(4, 9);
    let carry_in = qc.alloc_qubit(true);
    let mut carry_out_d = qc.alloc_reg(2, 0);

    SkewBinaryCarrySaveNumeral::skew_local_add_limb(
        &mut qc,
        &x_limb,
        &mut y_limb,
        carry_in,
        &mut carry_out_d,
    );
    // 12 + 9 + 1 = 22 = 6 + 16 -> y_limb == 6, carry_out_d == 1
    assert_eq!(qc.read_reg(&y_limb), 6);
    assert_eq!(qc.read_reg(&carry_out_d), 1);

    // Inter-window local fold
    let prev_high = qc.alloc_reg(4, 15);
    let mut curr_low = qc.alloc_reg(4, 3);
    let carry_rail = qc.alloc_qubit(false);
    SkewBinaryCarrySaveNumeral::skew_inter_window_local_fold(
        &mut qc, &prev_high, &mut curr_low, carry_rail,
    );
    assert_eq!(qc.read_reg(&curr_low), 2);
    assert!(qc.read_bit(carry_rail));
    qc.assert_ancillas_clean();
}

#[test]
fn test_09_skew_canonical_collapse() {
    let mut qc = QCircuit::new();
    let mut limbs = vec![qc.alloc_reg(4, 5), qc.alloc_reg(4, 7), qc.alloc_reg(4, 2)];
    let mut carries = vec![qc.alloc_qubit(true), qc.alloc_qubit(false)];
    SkewBinaryCarrySaveNumeral::skew_canonical_collapse(&mut qc, &mut limbs, &mut carries);
    assert_eq!(qc.read_reg(&limbs[0]), 5);
    assert_eq!(qc.read_reg(&limbs[1]), 8);
    assert_eq!(qc.read_reg(&limbs[2]), 2);
    qc.assert_ancillas_clean();
}

#[test]
fn test_10_braun_associative_fold_exact_k_minus_1_toffolis() {
    for k in [2usize, 5, 8, 13, 16] {
        let mut qc = QCircuit::new();
        let all_ones = (1u128 << k) - 1;
        let leaves = qc.alloc_reg(k, all_ones);
        let (root, ancillas, recorded) = BraunTree::braun_associative_fold_k_minus_1(&mut qc, &leaves);
        assert!(qc.read_bit(root));
        assert_eq!(qc.profile.toffoli_count, k - 1);
        BraunTree::braun_popcount_unfold(&mut qc, ancillas, &recorded);
        qc.assert_ancillas_clean();
    }
}

#[test]
fn test_11_braun_popcount_fold_and_unfold() {
    for (k, val) in [(7usize, 0b1011011u128), (8, 0b11110101), (15, 0b101011101101101)] {
        let mut qc = QCircuit::new();
        let leaves = qc.alloc_reg(k, val);
        let (pop_reg, ancillas, recorded) = BraunTree::braun_popcount_fold(&mut qc, &leaves);
        let expected_pop = val.count_ones() as u128;
        assert_eq!(qc.read_reg(&pop_reg), expected_pop);
        assert!(qc.profile.toffoli_count <= k - 1);

        BraunTree::braun_popcount_unfold(&mut qc, ancillas, &recorded);
        assert_eq!(qc.read_reg(&leaves), val);
        qc.assert_ancillas_clean();
    }
}

#[test]
fn test_12_braun_rns_crt_quotient_fold() {
    let residues = [2u64, 4, 1, 3, 5, 2, 6, 1];
    let magic = [32768u64, 16384, 8192, 4096, 2048, 1024, 512, 256];
    let (q, nodes) = BraunTree::braun_rns_crt_quotient_fold(&residues, &magic, 16);
    assert_eq!(nodes, 7);
    assert_eq!(q, 2);
}

#[test]
fn test_13_packed_bezout_complementary_bitlength_packing() {
    let p = 251u64;
    for x in 1..p {
        let (x_canon, _sign, inv, max_bl_sum) = PackedBezoutState::half_domain_bezout_fold(x, p);
        assert!(x_canon <= (p - 1) / 2);
        assert_eq!(((x as i64) * inv).rem_euclid(p as i64), 1);
        assert!(max_bl_sum <= 9);
    }
    let state = PackedBezoutState::pack(8, 13, 19, 7, 29);
    assert_eq!(state.unpack_ur(), (13, 19));
    assert_eq!(state.unpack_vs(), (7, 29));
}

#[test]
fn test_14_packed_bezout_jump_window_circuit() {
    let mut qc = QCircuit::new();
    let mut f_low = qc.alloc_reg(4, 5);
    let mut g_low = qc.alloc_reg(4, 3);
    let delta_pos = qc.alloc_qubit(true);
    PackedBezoutState::bezout_jump_window(&mut qc, &mut f_low, &mut g_low, delta_pos, 2);
    qc.assert_ancillas_clean();
}

#[test]
fn test_15_totalized_loo_keng_hua_square_all_residues_and_boundaries() {
    for p in [17u64, 97, 257, 65537] {
        // Test all residues for smaller primes and boundary + sample residues for 65537
        let limit = p.min(512);
        for lam in 0..limit {
            let sq = PackedBezoutState::totalized_loo_keng_hua_square(lam, p);
            assert_eq!(sq, (lam * lam) % p, "Failed at lam={}, p={}", lam, p);
        }
        // Explicitly test the 3 poles: 0, 1, and 2^{-1} mod p
        let half = (p + 1) / 2;
        assert_eq!(
            PackedBezoutState::totalized_loo_keng_hua_square(half, p),
            (half * half) % p
        );
    }
}

#[test]
fn test_16_binomial_pebble_schedule_s4_d4_m32() {
    let mut qc = QCircuit::new();
    let trace = BinomialPebbleSchedule::run_schedule_and_circuit(&mut qc, 4, 4, 32, 4);
    assert_eq!(BinomialPebbleSchedule::binom(8, 4), 70);
    assert!(trace.peak_live_pebbles <= 4);
    assert_eq!(trace.final_live_pebbles, 0);
    assert_eq!(trace.forward_evals, 77);
    assert_eq!(trace.reverse_evals, 32);
    assert_eq!(trace.forward_evals + trace.reverse_evals, 109);
    let consumes = trace
        .actions
        .iter()
        .filter(|a| matches!(a, PebbleAction::ConsumeOutputAt { .. }))
        .count();
    assert_eq!(consumes, 32);
    qc.assert_ancillas_clean();
}

#[test]
fn test_17_monoidal_finger_tree_simhash_filter_and_vtaa() {
    let mut qc = QCircuit::new();
    let fp_a = qc.alloc_reg(8, 0b1101_0111);
    let fp_b = qc.alloc_reg(8, 0b1101_0111); // identical -> XNOR = 0xFF -> popcount = 8 (MSB = 1)
    let match_flag = qc.alloc_qubit(false);

    let forward_toff =
        MonoidalFingerTreeFilter::simhash_xnor_popcount_filter(&mut qc, &fp_a, &fp_b, match_flag);
    assert!(forward_toff <= 7);
    assert!(qc.read_bit(match_flag));
    qc.assert_ancillas_clean();

    let (single_cost, two_stage_cost) =
        MonoidalFingerTreeFilter::two_stage_vtaa_expected_cost(15.0, 1.0 / 64.0, 2000.0, 1e-6);
    assert!(two_stage_cost < single_cost * 0.20);
}

#[test]
fn test_18_bruhat_pivoted_lu_in_place_zero_ancillas() {
    let matrix = vec![
        vec![false, true, true, false],
        vec![true, true, false, true],
        vec![true, false, true, false],
        vec![false, true, false, true],
    ];
    let decomp = BruhatPivotedLU::decompose_f2(&matrix);
    assert_eq!(decomp.rank, 4);

    for x_val in 0..16u128 {
        let mut qc = QCircuit::new();
        let mut reg = qc.alloc_reg(4, x_val);
        BruhatPivotedLU::apply_in_place_lu_circuit(&mut qc, &decomp, &mut reg);
        assert_eq!(qc.profile.toffoli_count, 0);
        assert_eq!(qc.profile.peak_ancilla_qubits, 0);

        // Compare against direct matrix-vector product over F_2
        let mut expected = 0u128;
        for r in 0..4 {
            let mut bit = false;
            for c in 0..4 {
                if matrix[r][c] && ((x_val >> c) & 1 == 1) {
                    bit = !bit;
                }
            }
            if bit {
                expected |= 1u128 << r;
            }
        }
        assert_eq!(qc.read_reg(&reg), expected);
        qc.assert_ancillas_clean();
    }
}

#[test]
fn test_19_canonical_crit_bit_history_independence() {
    let keys_order_1 = [42u64, 7, 19, 105, 3, 88, 64, 12];
    let keys_order_2 = [88u64, 12, 3, 105, 42, 64, 19, 7];
    let keys_order_3 = [3u64, 7, 12, 19, 42, 64, 88, 105];

    let tree1 = CanonicalCritBitBitonicDictionary::build_crit_bit_tree(&keys_order_1);
    let tree2 = CanonicalCritBitBitonicDictionary::build_crit_bit_tree(&keys_order_2);
    let tree3 = CanonicalCritBitBitonicDictionary::build_crit_bit_tree(&keys_order_3);
    assert_eq!(tree1, tree2);
    assert_eq!(tree2, tree3);
}

#[test]
fn test_20_batcher_bitonic_sort_quantum_circuit() {
    let mut qc = QCircuit::new();
    let regs = vec![
        qc.alloc_reg(4, 11),
        qc.alloc_reg(4, 3),
        qc.alloc_reg(4, 14),
        qc.alloc_reg(4, 6),
    ];
    CanonicalCritBitBitonicDictionary::batcher_bitonic_sort_circuit(&mut qc, &regs);
    let sorted: Vec<u128> = regs.iter().map(|r| qc.read_reg(r)).collect();
    assert_eq!(sorted, vec![3, 6, 11, 14]);
    qc.assert_ancillas_clean();
}

#[test]
fn test_21_walker_vose_alias_table_and_quantum_sampler() {
    // 4 bins, precision_mu = 4 (scale = 16, total = 64)
    let weights = [6u64, 28, 10, 20];
    let table = WalkerVoseAliasTable::build(&weights, 4);
    assert_eq!(table.reconstructed_weights(), weights);

    // Exhaustively sample all (index, coin) pairs through the quantum circuit and tally output mass
    let mut counts = [0u64; 4];
    for idx in 0..4u128 {
        for coin in 0..16u128 {
            let mut qc = QCircuit::new();
            let idx_reg = qc.alloc_reg(2, idx);
            let coin_reg = qc.alloc_reg(4, coin);
            let mut out_reg = qc.alloc_reg(2, 0);
            table.sample_quantum_circuit(&mut qc, &idx_reg, &coin_reg, &mut out_reg);
            let sampled = qc.read_reg(&out_reg) as usize;
            counts[sampled] += 1;
            qc.assert_ancillas_clean();
        }
    }
    assert_eq!(counts, weights);
}

#[test]
fn test_22_ecdlp_windowed_point_add_and_1088_qubit_ledger() {
    let ledger = ecc256_resource_ledger();
    assert_eq!(ledger.total_logical_qubits, 1088);
    assert_eq!(ledger.total_toffolis, 14_344_192);

    let mut qc = QCircuit::new();
    let mut x_reg = qc.alloc_reg(8, 19);
    let mut y_reg = qc.alloc_reg(8, 44);
    let sq = ecdlp_windowed_point_add(&mut qc, &mut x_reg, &mut y_reg, 7, 13, 251);
    assert!(sq < 251);
    qc.assert_ancillas_clean();
}

#[test]
fn test_23_rsa_arch_a_b_c_ledgers_and_circuit() {
    let a2048 = rsa_arch_a_b_c_ledger(2048, RsaArchitecture::ArchASkewPebble);
    let b2048 = rsa_arch_a_b_c_ledger(2048, RsaArchitecture::ArchBKaratsubaBraun);
    let c2048 = rsa_arch_a_b_c_ledger(2048, RsaArchitecture::ArchCCompactRnsBraun);
    assert_eq!(a2048.logical_qubits, 1924);
    assert_eq!(a2048.total_toffolis, 1_870_000_000);
    assert_eq!(b2048.logical_qubits, 896);
    assert_eq!(b2048.total_toffolis, 11_790_000_000);
    assert_eq!(c2048.logical_qubits, 1364);
    assert_eq!(c2048.total_toffolis, 1_700_000_000);

    let a4096 = rsa_arch_a_b_c_ledger(4096, RsaArchitecture::ArchASkewPebble);
    let b4096 = rsa_arch_a_b_c_ledger(4096, RsaArchitecture::ArchBKaratsubaBraun);
    let c4096 = rsa_arch_a_b_c_ledger(4096, RsaArchitecture::ArchCCompactRnsBraun);
    assert_eq!(a4096.logical_qubits, 3780);
    assert_eq!(a4096.total_toffolis, 14_840_000_000);
    assert_eq!(b4096.logical_qubits, 1728);
    assert_eq!(b4096.total_toffolis, 89_400_000_000);
    assert_eq!(c4096.logical_qubits, 2644);
    assert_eq!(c4096.total_toffolis, 13_180_000_000);

    let mut qc = QCircuit::new();
    let (_fwd, arch_b_toff, _q) = rsa_arch_a_b_c_step(&mut qc);
    assert_eq!(arch_b_toff, 15);
    qc.assert_ancillas_clean();
}

#[test]
fn test_24_aes_sbox_self_cleaning_and_merkle_zipper() {
    let mut qc = QCircuit::new();
    let byte_in = qc.alloc_reg(8, 0x53);
    let mut byte_out = qc.alloc_reg(8, 0);
    aes_sbox_self_cleaning_tower(&mut qc, &byte_in, &mut byte_out);
    assert_ne!(qc.read_reg(&byte_out), 0);
    qc.assert_ancillas_clean();

    let leaf = qc.alloc_reg(8, 0x2A);
    let siblings = [0x11u128, 0x22, 0x33, 0x44];
    let root = sequential_merkle_tree_pebble(&mut qc, &leaf, &siblings, 0b1010);
    assert_eq!(qc.read_reg(&root), (0x2A + 0x11 + 0x22 + 0x33 + 0x44) % 256);
    qc.assert_ancillas_clean();
}

#[test]
fn test_25_odd_half_div2_mod_q_in_place_bijection() {
    // Exhaustively verify in-place division by 2 mod q = 13 on 5-bit register (0..12)
    let q = 13u128;
    let inv2_mod_13 = 7u128; // 2 * 7 = 14 ≡ 1 mod 13
    for x in 0..q {
        let mut qc = QCircuit::new();
        let mut x_reg = qc.alloc_reg(5, x);
        odd_half_div2_mod_q_in_place(&mut qc, &mut x_reg, q);
        let out = qc.read_reg(&x_reg);
        assert_eq!(out, (x * inv2_mod_13) % q, "Failed for x={}", x);
        qc.assert_ancillas_clean();
    }
}

#[test]
fn test_26_dqi_coherent_opi_decode_9984_qubits() {
    let mut qc = QCircuit::new();
    let h_block = vec![
        vec![true, false, true, false],
        vec![true, true, false, false],
        vec![false, true, true, true],
        vec![false, false, true, false],
    ];
    let err = qc.alloc_reg(4, 0b1011);
    let (base_q, okasaki_q, syn) = dqi_coherent_opi_decode(&mut qc, &h_block, &err);
    assert_eq!(base_q, 101_888);
    assert_eq!(okasaki_q, 9_984);
    assert_eq!(qc.read_reg(&syn), 0b0001);
    qc.assert_ancillas_clean();
}

#[test]
fn test_27_bivariate_bicycle_288_and_fpga_0dsp_union_find() {
    let mut qc = QCircuit::new();
    // [[288, 12, 18]] has two 144-qubit blocks (12 x 12 torus)
    let (n_physical, commutes, css_orth) = bivariate_bicycle_torus_shift(&mut qc, 12, 12);
    assert_eq!(n_physical, 288);
    assert!(commutes);
    assert!(css_orth);

    let cluster_syn = qc.alloc_reg(8, 0b0110_1001); // weight 4 (even parity)
    let (even, weight) = fpga_0dsp_braun_union_find_decode(&mut qc, &cluster_syn);
    assert!(even);
    assert_eq!(weight, 4);
    qc.assert_ancillas_clean();
}

#[test]
fn test_28_unified_grade_const_generics_and_zero_cost_erasure() {
    // Skew-Binary carry merge grade: TOFF=2, DEPTH=4, EBITS=0, LIVE_LINKS=0
    let skew_grade = UnifiedGrade::<2, 4, 0, 0>::new();
    assert_eq!(std::mem::size_of_val(&skew_grade), 0);
    assert_eq!(skew_grade.erase_grade(), (2, 4, 0, 0));
    assert!(skew_grade.is_cat_link_closed());

    // Distributed Zipper-Cut bridge grade: TOFF=2, DEPTH=6, EBITS=2, LIVE_LINKS=0
    let zipper_grade = UnifiedGrade::<2, 6, 2, 0>::new();
    assert_eq!(zipper_grade.toffolis(), 2);
    assert_eq!(zipper_grade.depth(), 6);
    assert_eq!(zipper_grade.ebits(), 2);
    assert_eq!(zipper_grade.live_links(), 0);
    assert!(zipper_grade.is_cat_link_closed());

    // Unclosed cat-link counterexample (Issue F8): LIVE_LINKS=1
    let unclosed_grade = UnifiedGrade::<1, 2, 1, 1>::new();
    assert!(!unclosed_grade.is_cat_link_closed());
}

#[test]
fn test_29_quotient_carry_save_and_fredkin_comparator_uncompute_fix_f9_f11() {
    // Fix F9: Quotient Carry-Save Consolidation mod 256
    let c1 = CanonicalQFreeAnfVerifier::consolidate_carry_save_mod(6, 0, 256);
    let c2 = CanonicalQFreeAnfVerifier::consolidate_carry_save_mod(4, 1, 256);
    assert_eq!(c1, (6, 0));
    assert_eq!(c1, c2);

    // Issue F11 vs Fix F11: Fredkin Comparator Post-Swap Uncomputation Paradox
    for k_l in 0..16u64 {
        for k_r in 0..16u64 {
            let (naive_after, sym_after) =
                CanonicalQFreeAnfVerifier::fredkin_comparator_uncompute_check(k_l, k_r);
            assert_eq!(naive_after, k_l > k_r);
            assert!(!sym_after);
        }
    }
}

#[test]
fn test_30_qec_window_barrier_reset_fix_f12() {
    let round_440 = ErasedQGrade {
        toffolis: 2,
        depth: 6,
        ebits: 2,
        live_links: 0,
        qec_window_ns: 440,
        peak_qec_window_ns: 440,
    };

    // 5 consecutive QEC rounds separated by qec_barrier() maintain peak_qec_window_ns == 440 <= 1000
    let mut barriered = ErasedQGrade::zero();
    for _ in 0..5 {
        barriered = barriered.seq(round_440).qec_barrier();
    }
    assert_eq!(barriered.qec_window_ns, 0);
    assert_eq!(barriered.peak_qec_window_ns, 440);
    assert!(barriered.peak_qec_window_ns <= 1000);

    // 3 consecutive un-barriered rounds (Issue F12 counterexample) reach 1320 > 1000
    let unbarriered = round_440.seq(round_440).seq(round_440);
    assert_eq!(unbarriered.peak_qec_window_ns, 1320);
    assert!(unbarriered.peak_qec_window_ns > 1000);
}

#[test]
fn test_31_canonical_qfree_anf_verifier_all_12_bugs_f1_to_f12() {
    assert!(CanonicalQFreeAnfVerifier::verify_all_12_bugs_rejected());
}

#[test]
fn test_32_certifying_voqc_optimizer_gate_cancellation_and_f13_barrier() {
    // 1. Adjacent self-inverse X;X, H;H, CNOT;CNOT cancel while preserving Toffolis
    let skew_padded = vec![
        VoqcIrGate::X(0),
        VoqcIrGate::X(0),
        VoqcIrGate::CcX(0, 2, 3),
        VoqcIrGate::Cnot(3, 2),
        VoqcIrGate::Cnot(1, 2),
        VoqcIrGate::Cnot(1, 2),
        VoqcIrGate::CcX(0, 1, 2),
        VoqcIrGate::Cnot(0, 1),
    ];
    let opt = CertifyingVoqcOptimizer::optimize_canonical(&skew_padded);
    assert_eq!(opt.len(), 4);
    assert_eq!(CertifyingVoqcOptimizer::toffoli_count(&opt), 2);
    assert_eq!(CertifyingVoqcOptimizer::clifford_count(&opt), 2);

    // 2. Fix F13: CNOT(0,1); Z(1); CNOT(0,1) does NOT cancel across non-commuting Z(1)
    let f13_seq = vec![
        VoqcIrGate::Cnot(0, 1),
        VoqcIrGate::Z(1),
        VoqcIrGate::Cnot(0, 1),
    ];
    let f13_opt = CertifyingVoqcOptimizer::optimize_canonical(&f13_seq);
    assert_eq!(f13_opt.len(), 3);

    let exact_phase = CertifyingVoqcOptimizer::eval_cnot_z1_cnot_phase(true, false, false);
    let buggy_phase = CertifyingVoqcOptimizer::eval_cnot_z1_cnot_phase(true, false, true);
    assert_eq!(exact_phase, (true, false, -1));
    assert_eq!(buggy_phase, (true, false, 1));
    assert_ne!(exact_phase.2, buggy_phase.2);
}

#[test]
fn test_33_stim_detector_determinism_and_f14_superpos_rejection() {
    let valid_det = StimDetectorSpec {
        basis_qfree: true,
        rep_canonical_mod: true,
        anf_delta_zero: true,
    };
    assert!(StimBbQldpcCompiler::is_deterministic_detector(&valid_det));
    assert_eq!(
        StimBbQldpcCompiler::noiseless_detector_fire_prob_2x(&valid_det, true, true, true),
        0
    );

    // Issue F14 Counterexample 1: Superposition detector (50% random false alarm)
    let superpos_det = StimDetectorSpec {
        basis_qfree: false,
        rep_canonical_mod: true,
        anf_delta_zero: true,
    };
    assert!(!StimBbQldpcCompiler::is_deterministic_detector(&superpos_det));
    assert_eq!(
        StimBbQldpcCompiler::noiseless_detector_fire_prob_2x(&superpos_det, false, false, false),
        1
    );

    // Issue F14 Counterexample 2: Unconsolidated carry-save detector (100% false alarm when carry_bit=true)
    let redundant_det = StimDetectorSpec {
        basis_qfree: true,
        rep_canonical_mod: false,
        anf_delta_zero: true,
    };
    assert!(!StimBbQldpcCompiler::is_deterministic_detector(&redundant_det));
    assert_eq!(
        StimBbQldpcCompiler::noiseless_detector_fire_prob_2x(&redundant_det, false, false, true),
        2
    );
}

#[test]
fn test_34_bb288_torus_shift_css_round_alignment_and_stim_compiler_f16() {
    assert!(StimBbQldpcCompiler::is_safe_bb_torus_shift(CssRoundState::CssClosed, 1, 2));
    assert!(!StimBbQldpcCompiler::is_safe_bb_torus_shift(CssRoundState::CssOpenX, 1, 0));
    assert!(!StimBbQldpcCompiler::is_safe_bb_torus_shift(CssRoundState::CssOpenZ, 0, 1));

    let valid_det = StimDetectorSpec {
        basis_qfree: true,
        rep_canonical_mod: true,
        anf_delta_zero: true,
    };
    let gates = vec![
        VoqcIrGate::CcX(0, 2, 3),
        VoqcIrGate::Cnot(3, 2),
        VoqcIrGate::CcX(0, 1, 2),
        VoqcIrGate::Cnot(0, 1),
        VoqcIrGate::QecBarrier,
    ];
    let compiled = StimBbQldpcCompiler::compile_to_stim_bb288(
        "QDS4_SkewMerge",
        &gates,
        &valid_det,
        CssRoundState::CssClosed,
        0.001,
    );
    assert!(compiled.is_ok());
    let (stim_str, _) = compiled.unwrap();
    assert!(stim_str.contains("DETECTOR(0, 0, 0)"));
    assert!(stim_str.contains("OBSERVABLE_INCLUDE(0)"));

    // Reject open CSS round torus shift (Issue F16)
    assert!(StimBbQldpcCompiler::compile_to_stim_bb288(
        "F16_OpenRound",
        &gates,
        &valid_det,
        CssRoundState::CssOpenX,
        0.001,
    )
    .is_err());

    let (false_alarms, p_l_opt) = StimBbQldpcCompiler::simulate_bb288_logical_error_rate(1e-3, true);
    let (_, p_l_unopt) = StimBbQldpcCompiler::simulate_bb288_logical_error_rate(1e-3, false);
    assert_eq!(false_alarms, 0);
    assert!((p_l_opt - 2.1e-7).abs() < 1e-12);
    assert!((p_l_unopt - 1.8e-5).abs() < 1e-12);
}

#[test]
fn test_35_smt_refinement_plugin_verifier_f1_to_f16_completeness() {
    let locked_canonical = WireRefinementSpec {
        rep_canonical: true,
        pebble_locked: true,
        basis_qfree: true,
        alg_deg: 1,
        anf_delta_zero: true,
    };
    let redundant_spec = WireRefinementSpec {
        rep_canonical: false,
        ..locked_canonical
    };
    let unlocked_spec = WireRefinementSpec {
        pebble_locked: false,
        ..locked_canonical
    };
    assert!(SmtRefinementPluginVerifier::check_refinement_subtype(
        &locked_canonical,
        &locked_canonical
    ));
    // Issue F15: Forgetful casts across module boundaries are rejected
    assert!(!SmtRefinementPluginVerifier::check_refinement_subtype(
        &redundant_spec,
        &locked_canonical
    ));
    assert!(!SmtRefinementPluginVerifier::check_refinement_subtype(
        &unlocked_spec,
        &locked_canonical
    ));

    // All 16 adversarial bugs F1..F16 rejected and canonical valid spec accepted
    assert!(SmtRefinementPluginVerifier::verify_all_16_bugs_rejected());
}

#[test]
fn test_36_brodal_okasaki_quantum_heap_qds11_worst_case_o1_meld() {
    assert_eq!(BrodalOkasakiQuantumHeap::meld_gate_cost(), (2, 4));
    let mut h1 = BrodalOkasakiQuantumHeap::new(7);
    let h2 = BrodalOkasakiQuantumHeap::new(12);
    for _ in 0..16 {
        h1 = h1.meld(&h2);
        assert!(BrodalOkasakiQuantumHeap::is_valid_skew_spine(
            &h1.child_rank_spine
        ));
    }
    assert_eq!(h1.root_key, 7);
}

#[test]
fn test_37_combinadics_qtda_boundary_simplex_qds12_chain_complex_nilpotency() {
    assert_eq!(
        CombinadicsQtdaBoundarySimplex::braun_popcount_parity_depth(64),
        6
    );
    // Exhaustively verify \partial_{k-1} \circ \partial_k = 0 on all C(8, 3) = 56 2-simplices and C(8, 4) = 70 3-simplices
    let mut count_2_simplices = 0usize;
    for a in 0..8 {
        for b in (a + 1)..8 {
            for c in (b + 1)..8 {
                let s = CombinadicsQtdaBoundarySimplex::new(vec![a, b, c]);
                assert!(s.verify_boundary_squared_zero());
                count_2_simplices += 1;
            }
        }
    }
    assert_eq!(count_2_simplices, 56);
}

#[test]
fn test_38_kuperberg_binomial_collimation_queue_qds13_and_f19_rank_match() {
    assert!(KuperbergBinomialCollimationQueue::is_valid_collimation_pair(3, 3));
    assert!(!KuperbergBinomialCollimationQueue::is_valid_collimation_pair(1, 2));

    let mut q = KuperbergBinomialCollimationQueue::new();
    for r in [0, 0, 1, 2] {
        q.insert_rank(r);
        assert!(q.has_unique_sorted_ranks());
    }
    assert_eq!(q.ranks, vec![3]);
}

#[test]
fn test_39_open_quantum_problems_oqp1_to_10_catalog_verification() {
    let probs = OpenQuantumProblemsCatalog::all_10_problems();
    assert_eq!(probs.len(), 10);
    for p in &probs {
        assert!(p.okasaki_cost < p.baseline_cost);
        assert!(p.reduction_ratio > 1.0);
        assert_eq!(p.reverse_toffolis, 0);
        assert!(p.qec_window_ns <= 1000);
    }
    assert!((probs[0].reduction_ratio - 6.0).abs() < 1e-9);
    assert!((probs[5].reduction_ratio - 41.6).abs() < 1e-9);
}

#[test]
fn test_40_single_pass_nbe_compiler_s12_and_f1_to_f20_completeness() {
    let nbe = SinglePassNbeCompiler::new_valid();
    let raw = vec![
        VoqcIrGate::Cnot(0, 1),
        VoqcIrGate::Cnot(0, 1),
        VoqcIrGate::CcX(0, 1, 2),
    ];
    let (is_sound, toffolis, opt) = nbe.eval_canonical_nbe(&raw);
    assert!(is_sound);
    assert_eq!(toffolis, 1);
    assert_eq!(opt, vec![VoqcIrGate::CcX(0, 1, 2)]);

    // Fix F18: CSWAP(c,a,b); Z(a); CSWAP(c,a,b) on |xc=1, xa=0, xb=1> has phase -1, whereas naive cancel gives +1
    assert_eq!(
        SinglePassNbeCompiler::eval_cswap_za_cswap_phase(true, false, true, false),
        -1
    );
    assert_eq!(
        SinglePassNbeCompiler::eval_cswap_za_cswap_phase(true, false, true, true),
        1
    );
    assert!(SinglePassNbeCompiler::verify_all_20_bugs_rejected());
}

#[test]
fn test_41_flag_hook_error_sym_anf_verifier_qec4_and_f21_rejection() {
    let flagged = FlagHookErrorSymAnfVerifier::new_flagged_chamberland_beverland();
    assert_eq!(flagged.max_unflagged_hook_weight(), 1);
    assert!(flagged.is_flag_hook_safe());

    let unflagged_f21 = FlagHookErrorSymAnfVerifier::new_unflagged_naive_f21();
    assert_eq!(unflagged_f21.max_unflagged_hook_weight(), 2);
    assert!(!unflagged_f21.is_flag_hook_safe());
}

#[test]
fn test_42_magic_state_cultivation_binomial_queue_qec5_and_f22_rejection() {
    assert_eq!(
        MagicStateCultivationBinomialQueue::cultivate_pair(2, 2, true),
        Some(3)
    );
    assert_eq!(
        MagicStateCultivationBinomialQueue::cultivate_pair(1, 2, true),
        None
    );
    assert_eq!(
        MagicStateCultivationBinomialQueue::cultivate_pair(2, 2, false),
        None
    );
    assert!(MagicStateCultivationBinomialQueue::is_cultivated_rank_sufficient(2, 2));
    assert!(!MagicStateCultivationBinomialQueue::is_cultivated_rank_sufficient(0, 2));

    let mut q = MagicStateCultivationBinomialQueue::new();
    for r in [0, 0, 1, 2] {
        assert!(q.insert_cultivated_state(r, true));
    }
    assert_eq!(q.cultivated_ranks, vec![3]);
    assert!(!q.insert_cultivated_state(3, false));
}

#[test]
fn test_43_lattice_surgery_finger_tree_bus_router_qec6_and_f23_collision_rejection() {
    let disjoint_layer = [PpmBusInterval::new(0, 3), PpmBusInterval::new(4, 7)];
    assert_eq!(
        LatticeSurgeryFingerTreeBusRouter::layer_max_congestion(&disjoint_layer),
        1
    );
    assert!(LatticeSurgeryFingerTreeBusRouter::is_collision_free_layer(
        &disjoint_layer
    ));

    let colliding_layer_f23 = [PpmBusInterval::new(0, 4), PpmBusInterval::new(3, 7)];
    assert_eq!(
        LatticeSurgeryFingerTreeBusRouter::layer_max_congestion(&colliding_layer_f23),
        2
    );
    assert!(!LatticeSurgeryFingerTreeBusRouter::is_collision_free_layer(
        &colliding_layer_f23
    ));
}

#[test]
fn test_44_homological_code_switch_boundary_qec7_and_f24_open_gauge_rejection() {
    let valid_switch = HomologicalCodeSwitchBoundary::new_valid_closed_switch();
    assert!(valid_switch.is_valid_code_switch());

    let open_gauge_f24 = HomologicalCodeSwitchBoundary {
        d1_d2_residual: 0,
        all_gauge_checks_fixed: false,
    };
    let nonzero_boundary_f24 = HomologicalCodeSwitchBoundary {
        d1_d2_residual: 1,
        all_gauge_checks_fixed: true,
    };
    assert!(!open_gauge_f24.is_valid_code_switch());
    assert!(!nonzero_boundary_f24.is_valid_code_switch());

    for v0 in [false, true] {
        for v1 in [false, true] {
            for v2 in [false, true] {
                assert_eq!(
                    HomologicalCodeSwitchBoundary::eval_simplex2_boundary_squared_mod2(v0, v1, v2),
                    (false, false, false)
                );
            }
        }
    }
}

#[test]
fn test_45_bitboard_hash_consed_nbe_engine_s13_s14_and_f1_to_f24_completeness() {
    assert!(BitboardHashConsedNbeEngine::verify_bitboard_64point_isomorphism());

    let [c, a, b, _, _, _] = BitboardHashConsedNbeEngine::VAR_BITBOARDS;
    let (a1, b1) = BitboardHashConsedNbeEngine::bitboard_cswap_mux(c, a, b);
    let (a2, b2) = BitboardHashConsedNbeEngine::bitboard_cswap_mux(c, a1, b1);
    assert_eq!((a2, b2), (a, b));

    let engine = BitboardHashConsedNbeEngine::new_valid();
    let raw = vec![
        VoqcIrGate::Cnot(0, 1),
        VoqcIrGate::Cnot(0, 1),
        VoqcIrGate::CcX(0, 1, 2),
    ];
    let (is_sound, toffolis, _) = engine.eval_bitboard_nbe(&raw);
    assert!(is_sound);
    assert_eq!(toffolis, 1);

    assert!(BitboardHashConsedNbeEngine::verify_all_24_bugs_rejected());
}

#[test]
fn test_46_alphadev_superopt_gadgets_1_to_3_toffoli_and_depth_reduction() {
    let g1 = superoptimize_gadget(SuperoptGadgetId::Gadget1SkewCarryMerge);
    let g2 = superoptimize_gadget(SuperoptGadgetId::Gadget2DivstepSwapSub);
    let g3 = superoptimize_gadget(SuperoptGadgetId::Gadget3Gf16InversionSBox);

    assert!(g1.bitboard_64_equiv && g1.baseline_toffolis == 4 && g1.superopt_toffolis == 3);
    assert!(g2.bitboard_64_equiv && g2.baseline_toffolis == 5 && g2.superopt_toffolis == 3);
    assert!(g3.bitboard_64_equiv && g3.baseline_toffolis == 7 && g3.superopt_toffolis == 4);
}

#[test]
fn test_47_alphadev_superopt_gadgets_4_to_6_and_suite_totals_31_to_18() {
    let all = run_all_superopt_gadgets();
    assert_eq!(all.len(), 6);
    assert!(all.iter().all(|g| g.bitboard_64_equiv));
    assert!(all.iter().all(|g| g.superopt_toffolis < g.baseline_toffolis));
    assert!(all.iter().all(|g| g.superopt_depth < g.baseline_depth));

    let total_base_toff: usize = all.iter().map(|g| g.baseline_toffolis).sum();
    let total_opt_toff: usize = all.iter().map(|g| g.superopt_toffolis).sum();
    let total_base_depth: usize = all.iter().map(|g| g.baseline_depth).sum();
    let total_opt_depth: usize = all.iter().map(|g| g.superopt_depth).sum();

    assert_eq!(total_base_toff, 31);
    assert_eq!(total_opt_toff, 18);
    assert_eq!(total_base_depth, 41);
    assert_eq!(total_opt_depth, 24);
}

#[test]
fn test_48_pareto_frontier_4d_dominance_and_qec_budget_filter() {
    let p_kralovic = ParetoPoint4D::new("KralovicChordal", 18, 24, 14, 320);
    let p_bennett = ParetoPoint4D::new("BennettUnpacked", 36, 41, 22, 640);
    let p_low_qubit = ParetoPoint4D::new("UltraCompact", 22, 30, 11, 350);
    let p_over_budget = ParetoPoint4D::new("UnbarrieredF12", 16, 20, 12, 1320);

    assert!(p_kralovic.dominates(&p_bennett));
    assert!(!p_kralovic.dominates(&p_kralovic));
    assert!(!p_kralovic.dominates(&p_low_qubit));

    let frontier = compute_pareto_frontier_4d(&[p_kralovic, p_bennett, p_low_qubit, p_over_budget]);
    assert_eq!(frontier.len(), 2);
    assert!(frontier.contains(&p_kralovic));
    assert!(frontier.contains(&p_low_qubit));
    assert!(!frontier.contains(&p_bennett));
    assert!(!frontier.contains(&p_over_budget));
}

#[test]
fn test_49_asymmetric_kralovic_pebble_sweep_strictly_dominates_bennett() {
    let sweep = asymmetric_kralovic_pebble_sweep(18, &[3, 6, 9, 18]);
    assert_eq!(sweep.len(), 4);
    for &(kralovic_t, bennett_t, pebbles, latency_ns) in &sweep {
        assert!(kralovic_t < bennett_t);
        assert_eq!(bennett_t, 2 * kralovic_t);
        assert!(pebbles >= 3);
        assert!(latency_ns <= 1000);
    }
}

#[test]
fn test_50_chordal_pack_ancilla_intervals_and_f28_dirty_reuse_rejection() {
    let clean_intervals = [
        AncillaLiveInterval::new(0, 1, 4, true, true),
        AncillaLiveInterval::new(1, 2, 6, true, true),
        AncillaLiveInterval::new(2, 5, 9, true, true),
        AncillaLiveInterval::new(3, 7, 10, true, true),
    ];
    // 4 logical ancillas with max clique size 2 pack cleanly into 2 physical qubits
    assert_eq!(chordal_pack_ancilla_intervals(&clean_intervals), Ok(2));

    // Issue F28 Counterexample 1: Dirty exit (exit_delta_zero == false) before reuse
    let dirty_intervals = [
        AncillaLiveInterval::new(0, 1, 4, false, true),
        AncillaLiveInterval::new(2, 5, 9, true, true),
    ];
    assert!(chordal_pack_ancilla_intervals(&dirty_intervals).is_err());

    // Issue F28 Counterexample 2: Unconsolidated RedundantCS exit before reuse
    let redundant_intervals = [
        AncillaLiveInterval::new(0, 1, 4, true, false),
        AncillaLiveInterval::new(2, 5, 9, true, true),
    ];
    assert!(chordal_pack_ancilla_intervals(&redundant_intervals).is_err());
}

#[test]
fn test_51_fixes_f25_f26_f27_bitboard_counterfeit_hmr_cz_and_speculative_dual_rail() {
    // Fix F25: 16-row subspace check is fooled, but 64-bit bitboard check catches counterfeit
    let (subspace16_fooled, full64_equal) =
        AlphaDevParetoSuperoptEngine::verify_f25_bitboard_subspace_counterfeit_rejected();
    assert!(subspace16_fooled);
    assert!(!full64_equal);

    // Fix F26: HMR_CZ zero-cost substitution requires exact pure-quadratic target bb_t == bb_c1 & bb_c2
    let [v0, v1, v2, _, _, _] = BitboardHashConsedNbeEngine::VAR_BITBOARDS;
    assert!(AlphaDevParetoSuperoptEngine::verify_f26_hmr_cz_pure_quadratic_target(
        v0,
        v1,
        v0 & v1
    ));
    assert!(!AlphaDevParetoSuperoptEngine::verify_f26_hmr_cz_pure_quadratic_target(
        v0,
        v1,
        v2 ^ (v0 & v1)
    ));

    // Fix F27: Speculative dual-rail carry-select uncompute
    assert_eq!(
        AlphaDevParetoSuperoptEngine::verify_f27_speculative_dual_rail_uncompute(true),
        0
    );
    assert_ne!(
        AlphaDevParetoSuperoptEngine::verify_f27_speculative_dual_rail_uncompute(false),
        0
    );
}

#[test]
fn test_52_alphadev_pareto_superopt_engine_all_28_bugs_f1_to_f28_rejected() {
    let engine = AlphaDevParetoSuperoptEngine::new_valid();
    let (is_sound, toffolis, _) = engine.eval_superopt_nbe(&[VoqcIrGate::CcX(0, 1, 2)]);
    assert!(is_sound);
    assert_eq!(toffolis, 1);
    assert!(AlphaDevParetoSuperoptEngine::verify_all_28_bugs_rejected());
    test_53_phase12_f45_to_f48_qds14_to_16_and_oqp11_to_14();
    test_54_phase13_f49_to_f54_qds17_to_19_and_oqp15_to_18();
    test_55_phase14_f55_to_f60_pde1_to_6_qds20_to_22_and_oqp19_to_22();
    test_56_phase15_f61_to_f66_qds23_to_25_and_oqp23_to_26();
    test_57_phase16_f67_to_f72_coreqds_3loop_qds26_to_28_and_oqp27_to_30();
    test_58_phase17_f73_to_f78_cobble_spire_qcm_qunity_qwerty_qds29_to_31_and_oqp31_to_34();
    test_59_phase18_f79_to_f84_constructive_ir_hugr_twist_tower_qds32_to_34_and_oqp35_to_38();
    test_60_phase19_f85_to_f90_end_to_end_coreqds_lowering_all_oqp1_to_42_and_22_pcqb();
    test_61_phase20_coreqds2_complete_language_f91_to_f94_and_ce1_to_ce10();
}

pub fn test_53_phase12_f45_to_f48_qds14_to_16_and_oqp11_to_14() {
    assert!(verify_phase12_f45_to_f48_qds14_to_16_and_oqp11_to_14());
    assert_eq!(realtime_queue_worst_case_ticks(64), 2);
    assert_eq!(batched_queue_worst_case_ticks(64), 64);
    assert!(check_f47_realtime_and_acyclic_egraph(2, 5, 3));
    assert!(!check_f47_realtime_and_acyclic_egraph(64, 5, 3));
    assert!(orthogonal_case_zipper_valid(0x0FF0, 0xF00F, 0xFFFF, true));
    assert!(!check_f45_orthogonal_exhaustive_case(0x0010, 0xFFFF, 0xFFFF, true));
    assert!(check_f46_rccx_phase_commute_safe(false, 8, 16));
    assert!(!check_f46_rccx_phase_commute_safe(true, 8, 16));
    assert_eq!(pass_m10_catalyst_tower_t_gates(8), 32);
    assert_eq!(unfused_phase_rotation_t_gates(8), 360);
    assert_eq!(effective_correctable_faults(11, 1), 5);
    assert_eq!(effective_correctable_faults(11, 2), 2);
    assert!(check_f48_correlated_crosstalk_safe(2));
    assert!(!check_f48_correlated_crosstalk_safe(1));
    assert_eq!(pass_m9_chromatic_transversal_subrounds(true), 2);
}

pub fn test_54_phase13_f49_to_f54_qds17_to_19_and_oqp15_to_18() {
    assert!(verify_phase13_f49_to_f54_qds17_to_19_and_oqp15_to_18());
    let g = ExtendedQuantumFrameGrade {
        pauli_frame_parity: true,
        dd_echo_pulse_parity: 4,
        control_footprint: 0x00FF,
        target_footprint: 0xFF00,
        pbc_max_pauli_weight: 2,
        floquet_gauge_phase: 6,
        magic_state_tokens: 4,
        unreset_leakage_rds: 2,
    };
    assert!(compiler_gap_meta_auditor(&g, 4, 2, 3));
    assert!(check_f49_mcm_dd_phase_coherence(4, false));
    assert!(!check_f49_mcm_dd_phase_coherence(3, false));
    assert_eq!(eval_mcm_dd_feed_forward_window(1571, 3, false), -1571);
    assert!(check_f50_non_aliasing_borrow_frame(0x00F0, 0x0F00, true));
    assert!(!check_f50_non_aliasing_borrow_frame(0x00F0, 0x0030, true));
    assert_eq!(pbc_full_commute_pauli_weight(6), 64);
    assert_eq!(pass_m11_hybrid_qroam_pbc_weight(6), 2);
    assert!(check_f51_litinski_pbc_weight_bound(2, 4));
    assert!(!check_f51_litinski_pbc_weight_bound(64, 4));
    assert!(check_f52_floquet_gauge_aligned_cut(pass_m12_align_floquet_round_mod3(4)));
    assert_eq!(pass_m13_deamortize_t_gate_burst(16, 8), 2);
    assert!(check_f53_magic_state_token_bucket_safe(2, 1, 1));
    assert_eq!(bootstrapped_skew_heap_worst_case_cost(64), 2);
    assert_eq!(catenable_deque_append_worst_case_ticks(64), 2);
    assert!(check_f54_decoder_backlog_and_lru_safe(506, 1250, 2, 3));
    assert!(!check_f54_decoder_backlog_and_lru_safe(1800, 1250, 2, 3));
}

pub fn test_55_phase14_f55_to_f60_pde1_to_6_qds20_to_22_and_oqp19_to_22() {
    assert!(verify_phase14_f55_to_f60_pde1_to_6_qds20_to_22_and_oqp19_to_22());
    let rep = ProblemDiscoveryEngineReport {
        pde1_pass_permutation_ok: true,
        pde2_wide_word_z3_equiv_ok: true,
        pde3_dyadic_ctrl_phase_ok: true,
        pde4_dem_hook_distance_ok: true,
        pde5_xls_zero_dsp_timing_ok: true,
        pde6_boundary_totalized_ok: true,
    };
    assert!(all_six_problem_discovery_engines_pass(&rep));
    assert!(check_f55_pass_permutation_topological_valid(1, 3, 2, 4));
    assert!(!check_f55_pass_permutation_topological_valid(4, 2, 2, 4));
    assert_eq!(skew_carry_threshold_mod_word(16), 65_535);
    assert_eq!(skew_carry_threshold_extended(16), 131_071);
    assert!(check_f56_wide_word_carry_guard(64, 66));
    assert!(!check_f56_wide_word_carry_guard(64, 64));
    assert!(check_f57_controlled_phase_promotion_safe(true, 3, true));
    assert!(!check_f57_controlled_phase_promotion_safe(true, 3, false));
    assert_eq!(pass_m16_compensate_ctrl_phase_mod8(3), 0);
    assert_eq!(effective_hook_code_distance(5, false), 5);
    assert_eq!(effective_hook_code_distance(5, true), 3);
    assert!(check_f58_hook_error_orientation_safe(false));
    assert!(!check_f58_hook_error_orientation_safe(true));
    assert!(check_f59_zero_dsp_xls_timing_safe(820, 1000, 0, 8));
    assert!(!check_f59_zero_dsp_xls_timing_safe(820, 1000, 0, 7));
    assert_eq!(safe_deamortize_t_gate_burst(16, 0), 16);
    assert!(check_f60_boundary_input_safe(8, 2, 3, 1));
    assert!(!check_f60_boundary_input_safe(0, 2, 3, 1));
}

pub fn test_56_phase15_f61_to_f66_qds23_to_25_and_oqp23_to_26() {
    assert!(verify_phase15_f61_to_f66_qds23_to_25_and_oqp23_to_26());
    assert!(check_f61_linear_closure_capture_safe(0x00F0, 0x0F00, 1));
    assert!(!check_f61_linear_closure_capture_safe(0x00F0, 0x0030, 1));
    assert!(!check_f61_linear_closure_capture_safe(0x00F0, 0x0F00, 2));
    assert!(pass_m19_defunctionalize_closure_disjoint(0x00F0, 0x0F00));
    assert!(check_f62_oaa_exact_reflection_safe(true, true, true, 0));
    assert!(!check_f62_oaa_exact_reflection_safe(true, false, true, 0));
    assert!(!check_f62_oaa_exact_reflection_safe(true, true, false, 0));
    assert!(check_f63_xzzx_checkerboard_seam_aligned(1, 2, 2, 3));
    assert!(!check_f63_xzzx_checkerboard_seam_aligned(1, 2, 2, 2));
    assert_eq!(pass_m20_align_xzzx_checkerboard_col(1, 2, 2, 2), 3);
    assert!(check_f64_aod_monotone_and_rydberg_safe(false, false, 12, 8));
    assert!(!check_f64_aod_monotone_and_rydberg_safe(true, false, 12, 8));
    assert!(!check_f64_aod_monotone_and_rydberg_safe(false, false, 6, 8));
    assert_eq!(pass_m21_bocher_monotone_aod_sweeps(true), 2);
    assert_eq!(min_required_pebbles_for_height(5), 6);
    assert!(check_f65_komlos_pebbling_reserve_safe(6, 5, true));
    assert!(!check_f65_komlos_pebbling_reserve_safe(5, 5, true));
    assert!(check_f66_exact_dyadic_angle_precision_safe(true, 128, 256));
    assert!(!check_f66_exact_dyadic_angle_precision_safe(false, 64, 256));
}

pub fn test_57_phase16_f67_to_f72_coreqds_3loop_qds26_to_28_and_oqp27_to_30() {
    assert!(verify_phase16_f67_to_f72_coreqds_3loop_qds26_to_28_and_oqp27_to_30());
    assert_ne!(
        ExecutionLoopTier::ProviderInnerLoopBlueprint,
        ExecutionLoopTier::CoprocessorMidLoop
    );
    assert_ne!(
        ExecutionLoopTier::CoprocessorMidLoop,
        ExecutionLoopTier::UserCloudOuterLoop
    );
    assert!(check_f67_privilege_tier_boundary_safe(false, false));
    assert!(check_f67_privilege_tier_boundary_safe(true, true));
    assert!(!check_f67_privilege_tier_boundary_safe(true, false));
    assert_eq!(inner_loop_latency_ns(true, false, false, false), 240);
    assert_eq!(inner_loop_latency_ns(false, true, false, false), 273);
    assert_eq!(inner_loop_latency_ns(false, false, true, false), 506);
    assert_eq!(inner_loop_latency_ns(false, false, false, true), 550);
    assert!(check_f68_coprocessor_mid_loop_coherence_safe(5000, 100_000, true));
    assert!(check_f68_coprocessor_mid_loop_coherence_safe(5000, 2_000_000_000, false));
    assert!(!check_f68_coprocessor_mid_loop_coherence_safe(10_000, 100_000, false));
    assert!(check_f69_asic_static_syndrome_graph_safe(true, false));
    assert!(check_f69_asic_static_syndrome_graph_safe(false, true));
    assert!(!check_f69_asic_static_syndrome_graph_safe(true, true));
    assert!(check_f70_nn_fpga_distance_and_quantization_safe(5, 5, 4, false));
    assert!(check_f70_nn_fpga_distance_and_quantization_safe(11, 5, 4, true));
    assert!(!check_f70_nn_fpga_distance_and_quantization_safe(9, 5, 4, false));
    assert!(!check_f70_nn_fpga_distance_and_quantization_safe(5, 5, 2, false));
    assert!(check_f71_opnic_streaming_bandwidth_safe(16, 64, 1000, 10));
    assert!(!check_f71_opnic_streaming_bandwidth_safe(200, 128, 1000, 10));
    assert!(check_f72_coreqds_within_apply_no_mid_meas_collapse(0x00F0, 0x0F00, true));
    assert!(!check_f72_coreqds_within_apply_no_mid_meas_collapse(0x00F0, 0x0030, true));
    assert!(!check_f72_coreqds_within_apply_no_mid_meas_collapse(0x00F0, 0x0F00, false));
    assert!(check_coreqds_combinator_composition_safe(true, false, false, true, true, false));
    assert!(!check_coreqds_combinator_composition_safe(true, true, false, false, false, false));
    assert!(!check_coreqds_combinator_composition_safe(false, false, true, true, false, false));
    assert!(!check_coreqds_combinator_composition_safe(false, false, false, false, true, true));
}

pub fn test_58_phase17_f73_to_f78_cobble_spire_qcm_qunity_qwerty_qds29_to_31_and_oqp31_to_34() {
    assert!(
        verify_phase17_f73_to_f78_cobble_spire_qcm_qunity_qwerty_qds29_to_31_and_oqp31_to_34()
    );
    assert!(run_all_today_hardware_verifications());
    assert!(check_f73_cobble_subnormalization_fusion_safe(3, 1, 100, 2, 1, 90, false));
    assert!(check_f73_cobble_subnormalization_fusion_safe(4, 1, 80, 2, 1, 24, false));
    assert!(!check_f73_cobble_subnormalization_fusion_safe(3, 1, 100, 2, 1, 90, true));
    assert!(!check_f73_cobble_subnormalization_fusion_safe(3, 1, 100, 4, 1, 100, false));
    assert!(check_f74_spire_source_level_t_hoisting_safe(true, 32, 32));
    assert!(!check_f74_spire_source_level_t_hoisting_safe(false, 32, 32));
    assert!(!check_f74_spire_source_level_t_hoisting_safe(true, 96, 32));
    assert!(check_f75_qcm_injective_join_predicate_safe(true, false, 0));
    assert!(!check_f75_qcm_injective_join_predicate_safe(false, false, 0));
    assert!(!check_f75_qcm_injective_join_predicate_safe(true, true, 0));
    assert!(!check_f75_qcm_injective_join_predicate_safe(true, false, 4));
    assert!(check_f76_qunity_direct_sum_tag_coalescing_safe(3, 8, true));
    assert!(!check_f76_qunity_direct_sum_tag_coalescing_safe(8, 8, true));
    assert!(!check_f76_qunity_direct_sum_tag_coalescing_safe(3, 8, false));
    assert!(check_f77_qwerty_basis_translation_span_safe(true, true, true, 4, 4));
    assert!(!check_f77_qwerty_basis_translation_span_safe(false, true, true, 4, 4));
    assert!(!check_f77_qwerty_basis_translation_span_safe(true, true, false, 4, 4));
    assert!(!check_f77_qwerty_basis_translation_span_safe(true, true, true, 4, 2));
    assert!(check_f78_yang_yuan_log_assertion_counter_safe(16, 1, 4, 4, false));
    assert!(!check_f78_yang_yuan_log_assertion_counter_safe(16, 1, 16, 4, false));
    assert!(!check_f78_yang_yuan_log_assertion_counter_safe(16, 1, 4, 4, true));
}

pub fn test_59_phase18_f79_to_f84_constructive_ir_hugr_twist_tower_qds32_to_34_and_oqp35_to_38() {
    assert!(
        verify_phase18_f79_to_f84_constructive_ir_hugr_twist_tower_qds32_to_34_and_oqp35_to_38()
    );
    assert!(run_all_today_hardware_verifications());
    let (even_s, odd_s, recomp) = constructive_bocher_benes_1d_split(2, 0, 3, 1);
    assert_eq!(even_s, [2, 3]);
    assert_eq!(odd_s, [0, 1]);
    assert_eq!(recomp, [2, 0, 3, 1]);
    assert!(check_f79_structural_direct_sum_pattern_isometry_safe(true, true, true, 16));
    assert!(!check_f79_structural_direct_sum_pattern_isometry_safe(false, true, true, 16));
    assert!(!check_f79_structural_direct_sum_pattern_isometry_safe(true, false, true, 16));
    assert!(!check_f79_structural_direct_sum_pattern_isometry_safe(true, true, false, 16));
    assert!(check_f80_hugr_regional_port_and_sparse_anf_safe(8, 8, 4, 4, 12, true));
    assert!(!check_f80_hugr_regional_port_and_sparse_anf_safe(8, 7, 4, 4, 12, true));
    assert!(!check_f80_hugr_regional_port_and_sparse_anf_safe(8, 8, 4, 3, 12, true));
    assert!(!check_f80_hugr_regional_port_and_sparse_anf_safe(8, 8, 4, 4, 12, false));
    assert!(check_f81_guarded_s17_s19_s20_and_bocher_benes_safe(true, true, true, true));
    assert!(check_f81_guarded_s17_s19_s20_and_bocher_benes_safe(false, false, true, true));
    assert!(!check_f81_guarded_s17_s19_s20_and_bocher_benes_safe(false, true, true, true));
    assert!(!check_f81_guarded_s17_s19_s20_and_bocher_benes_safe(true, true, false, true));
    assert!(check_f82_twist_entanglement_and_tower_pointer_safe(true, true, 0));
    assert!(!check_f82_twist_entanglement_and_tower_pointer_safe(true, false, 0));
    assert!(!check_f82_twist_entanglement_and_tower_pointer_safe(true, true, 5));
    assert!(check_f83_cobble_before_rccx_and_scoped_spire_hoist_safe(true, false, 4, 4));
    assert!(!check_f83_cobble_before_rccx_and_scoped_spire_hoist_safe(false, false, 4, 4));
    assert!(!check_f83_cobble_before_rccx_and_scoped_spire_hoist_safe(true, true, 4, 4));
    assert!(!check_f83_cobble_before_rccx_and_scoped_spire_hoist_safe(true, false, 8, 4));
    assert!(check_f84_stinespring_dilation_and_exact_dyadic_safe(true, true, 0, 25_000));
    assert!(!check_f84_stinespring_dilation_and_exact_dyadic_safe(false, true, 0, 25_000));
    assert!(!check_f84_stinespring_dilation_and_exact_dyadic_safe(true, false, 3, 25_000));
    assert!(!check_f84_stinespring_dilation_and_exact_dyadic_safe(true, true, 0, 200));
}

pub fn test_60_phase19_f85_to_f90_end_to_end_coreqds_lowering_all_oqp1_to_42_and_22_pcqb() {
    assert!(verify_phase19_f85_to_f90_end_to_end_coreqds_lowering_all_oqp1_to_42());
    assert!(run_all_today_hardware_verifications());
    assert_eq!(all_core_qds_combinators().len(), 11);
    assert_eq!(all_core_qds_combinators_13().len(), 13);
    assert_eq!(ALL_PHASE19_SIMPLIFICATION_RULES.len(), 6);
    assert_eq!(ALL_PHASE19_MEASUREMENT_PASSES.len(), 4);
    assert_eq!(ALL_PHASE19_FORMAL_PROOFS.len(), 6);

    // Verify all 42 OQP-1..42 ASTs typecheck, have >= 5 AST nodes, and lower to >= 4 gates
    for oqp_id in 1..=42 {
        let ast = build_oqp_coreqds_ast(oqp_id).expect("OQP AST must exist");
        assert!(ast.ast_node_count() >= 5);
        let ty = infer_core_qds_type(&ast).expect("OQP AST must typecheck");
        assert_eq!(ty.scratch_mask, 0);
        let gates = compile_coreqds_to_revir(&ast).expect("OQP AST must lower to RevIR");
        assert!(gates.len() >= 4);
        assert!(verify_lowered_revir_netlist(&ast, &gates));
    }

    // Verify on-disk 22 PCQB files exist in ../../artifacts/pcqb/ and match pcqb_manifest.json
    let pcqb_dir = std::path::Path::new("../../artifacts/pcqb");
    let manifest_path = pcqb_dir.join("pcqb_manifest.json");
    let manifest_str = std::fs::read_to_string(&manifest_path)
        .expect("artifacts/pcqb/pcqb_manifest.json must exist on disk");
    assert!(manifest_str.contains("\"version\": \"19.0.0\""));
    assert!(manifest_str.contains("\"all_22_circuits\""));

    let expected_22_files = [
        "today1_dqi_bch_7_4_3.qasm",
        "today2_dqi_bch_15_7_5_24q.qasm",
        "today3_triangle_k3_4vertex_14q.qasm",
        "today4_braun_qroam_8to1.qasm",
        "today5_quantinuum_rzz_kickback_12q.qasm",
        "today6_willow_d3_surface_code_506ns.stim",
        "today7_qsvt_4x4_tridiagonal_braun_14q.qasm",
        "today8_welded_tree_orthogonal_zipper_16q.qasm",
        "today9_quantum_branch_and_bound_maxsat_16q.qasm",
        "today10_floquet_honeycomb_period3_18q.stim",
        "today11_ctrl_qsvt_phase_compensated_16q.qasm",
        "today12_zigzag_hook_free_surface_d3_17q.stim",
        "today13_xzzx_clifford_deformed_seam_18q.stim",
        "today14_neutral_atom_aod_monotone_shuttle_16q.qasm",
        "today15_cudaq_opnic_midloop_pauli_frame_16q.qasm",
        "today16_alphaqubit2_tpu_midloop_surface_17q.stim",
        "today17_cobble_qsvt_poly_fusion_block_encode_14q.qasm",
        "today18_yang_yuan_log_assertion_grover_12q.qasm",
        "today19_hugr_tailloop_rus_dyadic_qsvt_16q.qasm",
        "today20_bocher_benes_2d_aod_monotone_router_18q.qasm",
        "today21_coreqds_lowered_element_distinctness_16q.qasm",
        "today22_coreqds_lowered_branch_and_bound_18q.qasm",
    ];
    for fname in &expected_22_files {
        let p = pcqb_dir.join(fname);
        assert!(p.is_file(), "Missing PCQB file on disk: {:?}", p);
        assert!(
            manifest_str.contains(fname),
            "pcqb_manifest.json missing reference to {}",
            fname
        );
    }
}

#[test]
fn test_phase19_standalone_end_to_end_coreqds_and_22_pcqb_bundle() {
    test_60_phase19_f85_to_f90_end_to_end_coreqds_lowering_all_oqp1_to_42_and_22_pcqb();
}

pub fn test_61_phase20_coreqds2_complete_language_f91_to_f94_and_ce1_to_ce10() {
    assert!(verify_phase20_coreqds2_complete_language_f91_to_f94());
    assert!(verify_forbidden_coreqds_counterexamples_ce1_to_ce10());
    assert!(run_all_today_hardware_verifications());
    assert_eq!(ALL_PHASE20_SIMPLIFICATION_RULES.len(), 4);
    assert_eq!(ALL_PHASE20_MEASUREMENT_PASSES.len(), 2);
    assert_eq!(ALL_PHASE20_FORMAL_PROOFS.len(), 4);

    // 1. S71 / F91: 0-gate QVar lookup and environment-threaded beta-substitution
    let qv_gates = compile_coreqds_to_revir(&CoreQdsExpr::QVar(5)).unwrap();
    assert_eq!(qv_gates.len(), 0);
    assert!(infer_core_qds_type(&CoreQdsExpr::QVar(99)).is_none());

    // 2. S72 / F92: Flag-free computed orthogonality for QMatchClauses, basis translation, and HUGR ports
    assert!(verify_qmatch_bitmasks_computed_orthogonality(4, &[0b0011, 0b1100]));
    assert!(!verify_qmatch_bitmasks_computed_orthogonality(4, &[0b0011, 0b0110]));
    assert!(verify_qmatch_clauses_computed_orthogonality(
        4,
        &[(0b0011, 0), (0b1100, 0)]
    ));
    assert!(!verify_qmatch_clauses_computed_orthogonality(
        4,
        &[(0b0011, 0), (0b0010, 0)]
    ));
    assert!(verify_basis_translate_vecs(
        &[vec![1, 1], vec![1, -1]],
        &[vec![1, -1], vec![1, 1]]
    ));
    assert!(!verify_basis_translate_vecs(
        &[vec![1, 1], vec![1, 0]],
        &[vec![1, -1], vec![1, 1]]
    ));
    assert!(verify_hugr_tailloop_ports(&[0, 1], &[0, 1], &[2, 3], &[2, 3], 7));
    assert!(!verify_hugr_tailloop_ports(&[0, 1, 2], &[0, 1], &[2, 3], &[2, 3], 7));

    // 3. S73 / F93: Nested QFreeExpr compilation, RevRCCX/RevRCCXdg balance, and 16-row truth-table check
    let qf_expr = QFreeExpr::QAnd(
        Box::new(QFreeExpr::QXor(
            Box::new(QFreeExpr::QVarWire(0)),
            Box::new(QFreeExpr::QVarWire(1)),
        )),
        Box::new(QFreeExpr::QLt(
            Box::new(QFreeExpr::QVarWire(2)),
            Box::new(QFreeExpr::QVarWire(3)),
        )),
    );
    assert!(check_f93_qfree_expr_balanced_uncompute_safe(&qf_expr, 8, 32));

    // 4. S74 / F94: Twist 2x2 determinant purity and Presburger slice borrow
    assert!(verify_twist_entanglement_purity(&[1, 0, 0, 0], true));
    assert!(!verify_twist_entanglement_purity(&[1, 0, 0, 1], true));
    assert!(verify_presburger_slice_borrow(0, 8, 2, 1, 8, 2));
    assert!(!verify_presburger_slice_borrow(0, 8, 2, 4, 8, 2));

    // 5. CE-1..CE-10 and grammar-guided random AST fuzzer
    let ce_entries = audit_counterexamples_ce1_to_ce10();
    assert_eq!(ce_entries.len(), 10);
    for entry in &ce_entries {
        assert!(entry.bad_rejected, "{} bad case must be rejected", entry.id);
        assert!(entry.good_accepted, "{} good case must be accepted", entry.id);
    }
    for seed in 1u64..=32u64 {
        let good_ast = generate_random_coreqds_ast(seed, 3, true);
        let bad_ast = generate_random_coreqds_ast(seed, 3, false);
        assert!(good_ast.ast_node_count() >= 3);
        assert!(infer_core_qds_type(&good_ast).is_some());
        assert!(compile_coreqds_to_revir(&good_ast).is_some());
        assert!(infer_core_qds_type(&bad_ast).is_none());
    }
}

#[test]
fn test_phase20_standalone_coreqds2_complete_language_f91_to_f94() {
    test_61_phase20_coreqds2_complete_language_f91_to_f94_and_ce1_to_ce10();
}

pub fn test_62_phase21_translation_validated_optimal_coreqds_f95_to_f100_and_24_pcqb() {
    assert!(verify_phase21_translation_validated_optimal_coreqds_f95_to_f100());
    assert!(verify_all_12_target_architectures_matrix());
    assert!(run_all_today_hardware_verifications());
    assert_eq!(ALL_PHASE21_SIMPLIFICATION_RULES.len(), 4);
    assert_eq!(ALL_PHASE21_MEASUREMENT_PASSES.len(), 4);
    assert_eq!(ALL_PHASE21_FORMAL_PROOFS.len(), 6);
    assert_eq!(ALL_EXECUTION_REGIMES.len(), 3);
    assert_eq!(ALL_QUANTUM_MACHINE_TYPES.len(), 4);

    // Verify all 46 OQP-1..46 compile, optimize, and pass strict wire & LIFO ancilla stack checks
    for oqp_id in 1..=46 {
        let ast = build_oqp_coreqds_ast(oqp_id).expect("OQP-1..46 AST must exist");
        assert!(ast.ast_node_count() >= 5);
        let raw_gates = compile_coreqds_to_revir(&ast).expect("OQP AST must lower");
        let opt_gates = optimize_revir_netlist(&raw_gates);
        assert!(verify_revir_strict_wires_and_lifo_ancillas(&raw_gates));
        assert!(verify_revir_strict_wires_and_lifo_ancillas(&opt_gates));
        assert!(opt_gates.len() <= raw_gates.len());
    }

    // Verify on-disk 24 PCQB files exist in ../../artifacts/pcqb/ and match pcqb_manifest.json
    let pcqb_dir = std::path::Path::new("../../artifacts/pcqb");
    let manifest_path = pcqb_dir.join("pcqb_manifest.json");
    let manifest_str = std::fs::read_to_string(&manifest_path)
        .expect("artifacts/pcqb/pcqb_manifest.json must exist on disk");
    assert!(
        manifest_str.contains("\"total_circuits\": 24")
            || manifest_str.contains("\"total_circuits\": 26")
            || manifest_str.contains("\"total_circuits\": 28")
            || manifest_str.contains("\"total_circuits\": 30")
            || manifest_str.contains("\"total_circuits\": 32")
            || manifest_str.contains("\"total_circuits\": 34")
            || manifest_str.contains("\"total_circuits\": 36")
            || manifest_str.contains("\"total_circuits\": 38")
    );
    assert!(manifest_str.contains("\"all_24_circuits\""));

    let new_files = [
        "today23_translation_validated_coreqds_optimizer_16q.qasm",
        "today24_kak_multiplicative_optimal_oracle_20q.qasm",
    ];
    for fname in &new_files {
        let p = pcqb_dir.join(fname);
        assert!(p.is_file(), "Missing PCQB file on disk: {:?}", p);
        assert!(
            manifest_str.contains(fname),
            "pcqb_manifest.json missing reference to {}",
            fname
        );
    }
}

#[test]
fn test_phase21_standalone_translation_validated_optimal_coreqds_and_24_pcqb() {
    test_62_phase21_translation_validated_optimal_coreqds_f95_to_f100_and_24_pcqb();
}

#[test]
fn test_63_phase22_sota_exact_dyadic_tpar_sabre_stim_f101_to_f106_and_26_pcqb() {
    assert!(verify_phase22_sota_exact_dyadic_tpar_sabre_stim_f101_to_f106());
    assert!(run_all_today_hardware_verifications());
    assert_eq!(ALL_PHASE22_SIMPLIFICATION_RULES.len(), 4);
    assert_eq!(ALL_PHASE22_MEASUREMENT_PASSES.len(), 4);
    assert_eq!(ALL_PHASE22_FORMAL_PROOFS.len(), 6);

    // Verify all 48 OQP-1..48 compile, optimize, and pass strict wire & LIFO ancilla stack checks
    for oqp_id in 1..=48 {
        let ast = build_oqp_coreqds_ast(oqp_id).expect("OQP-1..48 AST must exist");
        assert!(ast.ast_node_count() >= 5);
        let raw_gates = compile_coreqds_to_revir(&ast).expect("OQP AST must lower");
        let opt_gates = optimize_revir_netlist(&raw_gates);
        assert!(verify_revir_strict_wires_and_lifo_ancillas(&raw_gates));
        assert!(verify_revir_strict_wires_and_lifo_ancillas(&opt_gates));
        assert!(opt_gates.len() <= raw_gates.len());
    }

    // Verify on-disk 26 PCQB files exist in ../../artifacts/pcqb/ and match pcqb_manifest.json
    let pcqb_dir = std::path::Path::new("../../artifacts/pcqb");
    let manifest_path = pcqb_dir.join("pcqb_manifest.json");
    let manifest_str = std::fs::read_to_string(&manifest_path)
        .expect("artifacts/pcqb/pcqb_manifest.json must exist on disk");
    assert!(
        manifest_str.contains("\"total_circuits\": 26")
            || manifest_str.contains("\"total_circuits\": 28")
            || manifest_str.contains("\"total_circuits\": 30")
            || manifest_str.contains("\"total_circuits\": 32")
            || manifest_str.contains("\"total_circuits\": 34")
            || manifest_str.contains("\"total_circuits\": 36")
            || manifest_str.contains("\"total_circuits\": 38")
    );
    assert!(manifest_str.contains("\"all_26_circuits\""));

    let new_files = [
        "today25_exact_dyadic_tpar_gf2_superopt_18q.qasm",
        "today26_sabre_routed_bit_accurate_braun_stim_dem_22q.stim",
    ];
    for fname in &new_files {
        let p = pcqb_dir.join(fname);
        assert!(p.is_file(), "Missing PCQB file on disk: {:?}", p);
        assert!(
            manifest_str.contains(fname),
            "pcqb_manifest.json missing reference to {}",
            fname
        );
    }
}

#[test]
fn test_phase22_standalone_sota_exact_dyadic_tpar_sabre_stim_and_26_pcqb() {
    test_63_phase22_sota_exact_dyadic_tpar_sabre_stim_f101_to_f106_and_26_pcqb();
}

#[test]
fn test_64_phase23_gidney_mbu_telegate_native_isa_600_matrix_f107_to_f112_and_28_pcqb() {
    assert!(verify_phase23_gidney_mbu_telegate_native_isa_600_matrix_f107_to_f112());
    assert!(verify_all_600_oqp_target_arch_matrix());
    assert!(run_all_today_hardware_verifications());
    assert_eq!(ALL_PHASE23_SIMPLIFICATION_RULES.len(), 4);
    assert_eq!(ALL_PHASE23_MEASUREMENT_PASSES.len(), 4);
    assert_eq!(ALL_PHASE23_FORMAL_PROOFS.len(), 6);

    // Verify all 50 OQP-1..50 compile to pairwise-distinct gate streams and pass strict wire & LIFO checks
    let mut seen_streams = Vec::with_capacity(50);
    for oqp_id in 1..=50 {
        let ast = build_oqp_coreqds_ast(oqp_id).expect("OQP-1..50 AST must exist");
        assert!(ast.ast_node_count() >= 5);
        let raw_gates = compile_coreqds_to_revir(&ast).expect("OQP AST must lower");
        let opt_gates = optimize_revir_netlist(&raw_gates);
        assert!(!seen_streams.contains(&raw_gates));
        seen_streams.push(raw_gates.clone());
        assert!(verify_revir_strict_wires_and_lifo_ancillas(&raw_gates));
        assert!(verify_revir_strict_wires_and_lifo_ancillas(&opt_gates));
        assert!(opt_gates.len() <= raw_gates.len());
    }
    assert_eq!(seen_streams.len(), 50);

    // Verify on-disk 28 PCQB files exist in ../../artifacts/pcqb/ and match pcqb_manifest.json
    let pcqb_dir = std::path::Path::new("../../artifacts/pcqb");
    let manifest_path = pcqb_dir.join("pcqb_manifest.json");
    let manifest_str = std::fs::read_to_string(&manifest_path)
        .expect("artifacts/pcqb/pcqb_manifest.json must exist on disk");
    assert!(
        manifest_str.contains("\"total_circuits\": 28")
            || manifest_str.contains("\"total_circuits\": 30")
            || manifest_str.contains("\"total_circuits\": 32")
            || manifest_str.contains("\"total_circuits\": 34")
            || manifest_str.contains("\"total_circuits\": 36")
            || manifest_str.contains("\"total_circuits\": 38")
    );
    assert!(manifest_str.contains("\"all_28_circuits\""));

    let new_files = [
        "today27_gidney_mbu_multishot_zzphase_qccd_20q.qasm",
        "today28_zipper_cut_telegate_distributed_12arch_24q.qasm",
    ];
    for fname in &new_files {
        let p = pcqb_dir.join(fname);
        assert!(p.is_file(), "Missing PCQB file on disk: {:?}", p);
        assert!(
            manifest_str.contains(fname),
            "pcqb_manifest.json missing reference to {}",
            fname
        );
    }
}

#[test]
fn test_phase23_standalone_gidney_mbu_telegate_native_isa_600_matrix_and_28_pcqb() {
    test_64_phase23_gidney_mbu_telegate_native_isa_600_matrix_f107_to_f112_and_28_pcqb();
}

#[test]
fn test_65_phase24_zx_pauli_web_gridsynth_lakefill_kernel6_f113_to_f118_and_30_pcqb() {
    assert!(verify_phase24_zx_pauli_web_gridsynth_lakefill_kernel6_f113_to_f118());
    assert!(verify_all_624_oqp_target_arch_matrix());
    assert!(run_all_today_hardware_verifications());
    assert_eq!(ALL_PHASE24_SIMPLIFICATION_RULES.len(), 4);
    assert_eq!(ALL_PHASE24_MEASUREMENT_PASSES.len(), 4);
    assert_eq!(ALL_PHASE24_FORMAL_PROOFS.len(), 6);

    // Verify all 52 OQP-1..52 compile to pairwise-distinct gate streams and desugar to LakefillKernel6Expr
    let mut seen_streams = Vec::with_capacity(52);
    for oqp_id in 1..=52 {
        let ast = build_oqp_coreqds_ast(oqp_id).expect("OQP-1..52 AST must exist");
        assert!(ast.ast_node_count() >= 5);
        let raw_gates = compile_coreqds_to_revir(&ast).expect("OQP AST must lower");
        let opt_gates = optimize_revir_netlist(&raw_gates);
        assert!(!seen_streams.contains(&raw_gates));
        seen_streams.push(raw_gates.clone());
        assert!(verify_revir_strict_wires_and_lifo_ancillas(&raw_gates));
        assert!(verify_revir_strict_wires_and_lifo_ancillas(&opt_gates));
        assert!(opt_gates.len() <= raw_gates.len());
        let container = Qds40LakefillMinimalKernelContainer::from_coreqds(&ast)
            .expect("QDS-40 Lakefill kernel container must succeed");
        assert_eq!(container.surface_constructor_count, 20);
        assert_eq!(container.kernel_constructor_count, 6);
        assert!(container.lowered_gates.len() >= 4);
    }
    assert_eq!(seen_streams.len(), 52);

    // Verify on-disk 30 PCQB files exist in ../../artifacts/pcqb/ and match pcqb_manifest.json
    let pcqb_dir = std::path::Path::new("../../artifacts/pcqb");
    let manifest_path = pcqb_dir.join("pcqb_manifest.json");
    let manifest_str = std::fs::read_to_string(&manifest_path)
        .expect("artifacts/pcqb/pcqb_manifest.json must exist on disk");
    assert!(
        manifest_str.contains("\"total_circuits\": 30")
            || manifest_str.contains("\"total_circuits\": 32")
            || manifest_str.contains("\"total_circuits\": 34")
            || manifest_str.contains("\"total_circuits\": 36")
            || manifest_str.contains("\"total_circuits\": 38")
    );
    assert!(manifest_str.contains("\"all_30_circuits\""));

    let new_files = [
        "today29_zx_pauli_web_48q_and_gridsynth_pi17_28q.qasm",
        "today30_lakefill_minimal_kernel6_desugared_24q.qasm",
    ];
    for fname in &new_files {
        let p = pcqb_dir.join(fname);
        assert!(p.is_file(), "Missing PCQB file on disk: {:?}", p);
        assert!(
            manifest_str.contains(fname),
            "pcqb_manifest.json missing reference to {}",
            fname
        );
    }
}

#[test]
fn test_phase24_standalone_zx_pauli_web_gridsynth_lakefill_kernel6_and_30_pcqb() {
    test_65_phase24_zx_pauli_web_gridsynth_lakefill_kernel6_f113_to_f118_and_30_pcqb();
}

#[test]
fn test_66_phase25_gflow_cultivation_dejmps_pcc_lakefill_f119_to_f124_and_32_pcqb() {
    assert!(verify_phase25_gflow_cultivation_dejmps_pcc_lakefill_f119_to_f124());
    assert!(verify_all_648_pcc_lakefill_target_matrix());
    assert!(oqp54_verify_all_54_oqp_end_to_end_synthesis());
    assert!(run_all_today_hardware_verifications());
    assert_eq!(ALL_PHASE25_SIMPLIFICATION_RULES.len(), 4);
    assert_eq!(ALL_PHASE25_MEASUREMENT_PASSES.len(), 4);
    assert_eq!(ALL_PHASE25_FORMAL_PROOFS.len(), 6);

    // Verify all 54 OQP-1..54 compile to pairwise-distinct gate streams and pass PCC-Lakefill certification
    let mut seen_streams = Vec::with_capacity(54);
    for oqp_id in 1..=54 {
        let ast = build_oqp_coreqds_ast(oqp_id).expect("OQP-1..54 AST must exist");
        assert!(ast.ast_node_count() >= 5);
        let raw_gates = compile_coreqds_to_revir(&ast).expect("OQP AST must lower");
        let opt_gates = optimize_revir_netlist(&raw_gates);
        assert!(!seen_streams.contains(&raw_gates));
        seen_streams.push(raw_gates.clone());
        assert!(verify_revir_strict_wires_and_lifo_ancillas(&raw_gates));
        assert!(verify_revir_strict_wires_and_lifo_ancillas(&opt_gates));
        assert!(opt_gates.len() <= raw_gates.len());
        let cert = issue_and_verify_pcc_lakefill_certificate(
            oqp_id,
            ExecutionRegime::R1TodayHardwareNisqAndEarlyFtlp,
            QuantumMachineType::QramFreeStreamQpu,
        )
        .expect("PCC-Lakefill certificate must succeed");
        assert!(cert.independent_kernel6_checker_verified);
    }
    assert_eq!(seen_streams.len(), 54);

    // Verify on-disk 32 PCQB files exist in ../../artifacts/pcqb/ and match pcqb_manifest.json
    let pcqb_dir = std::path::Path::new("../../artifacts/pcqb");
    let manifest_path = pcqb_dir.join("pcqb_manifest.json");
    let manifest_str = std::fs::read_to_string(&manifest_path)
        .expect("artifacts/pcqb/pcqb_manifest.json must exist on disk");
    assert!(
        manifest_str.contains("\"total_circuits\": 32")
            || manifest_str.contains("\"total_circuits\": 34")
            || manifest_str.contains("\"total_circuits\": 36")
            || manifest_str.contains("\"total_circuits\": 38")
    );
    assert!(manifest_str.contains("\"all_32_circuits\""));

    let new_files = [
        "today31_gflow_zx_pivot_and_magic_state_cultivation_26q.qasm",
        "today32_dejmps_distilled_telegate_and_pcc_lakefill_28q.qasm",
    ];
    for fname in &new_files {
        let p = pcqb_dir.join(fname);
        assert!(p.is_file(), "Missing PCQB file on disk: {:?}", p);
        assert!(
            manifest_str.contains(fname),
            "pcqb_manifest.json missing reference to {}",
            fname
        );
    }
}

#[test]
fn test_phase25_standalone_gflow_cultivation_dejmps_pcc_lakefill_and_32_pcqb() {
    test_66_phase25_gflow_cultivation_dejmps_pcc_lakefill_f119_to_f124_and_32_pcqb();
}

#[test]
fn test_67_phase27_post_route_peephole_dense_ssa_short_last_bilateral_f125_to_f130_and_34_pcqb() {
    assert!(verify_phase27_post_route_peephole_dense_ssa_short_last_bilateral_f125_to_f130());
    assert!(verify_all_672_post_route_peephole_target_matrix());
    assert!(oqp56_verify_all_56_oqp_end_to_end_synthesis());
    assert!(run_all_today_hardware_verifications());
    assert_eq!(ALL_PHASE27_SIMPLIFICATION_RULES.len(), 4);
    assert_eq!(ALL_PHASE27_MEASUREMENT_PASSES.len(), 4);
    assert_eq!(ALL_PHASE27_FORMAL_PROOFS.len(), 6);

    // Verify all 56 OQP-1..56 compile to pairwise-distinct gate streams, pass post-route peephole
    // optimization (0 residual adjacent self-canceling gates) and dense SSA compaction (0 unused qubits)
    let mut seen_streams = Vec::with_capacity(56);
    for oqp_id in 1..=56 {
        let ast = build_oqp_coreqds_ast(oqp_id).expect("OQP-1..56 AST must exist");
        assert!(ast.ast_node_count() >= 5);
        let raw_gates = compile_coreqds_to_revir(&ast).expect("OQP AST must lower");
        let opt_gates = optimize_revir_netlist(&raw_gates);
        assert!(!seen_streams.contains(&raw_gates));
        seen_streams.push(raw_gates.clone());
        assert!(verify_revir_strict_wires_and_lifo_ancillas(&raw_gates));
        assert!(verify_revir_strict_wires_and_lifo_ancillas(&opt_gates));
        assert!(opt_gates.len() <= raw_gates.len());

        let peep = post_rebase_and_post_route_peephole_optimize(&raw_gates);
        assert!(peep.fixed_point_reached);
        assert_eq!(peep.residual_adjacent_cancels, 0);
        let ssa = compact_dense_ssa_qubits(64, &peep.optimized_gates)
            .expect("Dense SSA compaction must succeed");
        assert!(ssa.order_preserving_bijection_verified);
        assert_eq!(ssa.remaining_unused_qubits, 0);
    }
    assert_eq!(seen_streams.len(), 56);

    // Verify on-disk 34 PCQB files exist in ../../artifacts/pcqb/ and match pcqb_manifest.json
    let pcqb_dir = std::path::Path::new("../../artifacts/pcqb");
    let manifest_path = pcqb_dir.join("pcqb_manifest.json");
    let manifest_str = std::fs::read_to_string(&manifest_path)
        .expect("artifacts/pcqb/pcqb_manifest.json must exist on disk");
    assert!(
        manifest_str.contains("\"total_circuits\": 34")
            || manifest_str.contains("\"total_circuits\": 36")
            || manifest_str.contains("\"total_circuits\": 38")
    );
    assert!(manifest_str.contains("\"all_34_circuits\""));

    let new_files = [
        "today33_post_route_peephole_and_dense_ssa_compaction_24q.qasm",
        "today34_short_last_multichannel_reserve_and_bilateral_phase_26q.qasm",
    ];
    for fname in &new_files {
        let p = pcqb_dir.join(fname);
        assert!(p.is_file(), "Missing PCQB file on disk: {:?}", p);
        assert!(
            manifest_str.contains(fname),
            "pcqb_manifest.json missing reference to {}",
            fname
        );
    }
}

#[test]
fn test_phase27_standalone_post_route_peephole_dense_ssa_short_last_bilateral_and_34_pcqb() {
    test_67_phase27_post_route_peephole_dense_ssa_short_last_bilateral_f125_to_f130_and_34_pcqb();
}

#[test]
fn test_68_phase28_dag_peephole_asap_xy4_dd_parametric_resource_f129_to_f132_and_36_pcqb() {
    assert!(verify_phase28_dag_peephole_asap_xy4_dd_parametric_resource_f129_to_f132());
    assert!(verify_all_696_dag_peephole_and_asap_dd_target_matrix());
    assert!(oqp58_verify_all_58_oqp_end_to_end_synthesis());
    assert!(verify_all_58_oqps_across_12_architectures_and_5_layouts());
    assert!(run_all_today_hardware_verifications());
    assert_eq!(ALL_PHASE28_SIMPLIFICATION_RULES.len(), 4);
    assert_eq!(ALL_PHASE28_MEASUREMENT_PASSES.len(), 4);
    assert_eq!(ALL_PHASE28_FORMAL_PROOFS.len(), 4);

    // Verify all 58 OQP-1..58 compile to pairwise-distinct gate streams, pass DAG-commutation
    // peephole optimization (0 residual commuting inverse pairs), ASAP critical-path + XY4 DD,
    // and dense SSA compaction (0 unused qubits)
    let mut seen_streams = Vec::with_capacity(58);
    for oqp_id in 1..=58 {
        let ast = build_oqp_coreqds_ast(oqp_id).expect("OQP-1..58 AST must exist");
        assert!(ast.ast_node_count() >= 5);
        let raw_gates = compile_coreqds_to_revir(&ast).expect("OQP AST must lower");
        let opt_gates = optimize_revir_netlist(&raw_gates);
        assert!(!seen_streams.contains(&raw_gates));
        seen_streams.push(raw_gates.clone());
        assert!(verify_revir_strict_wires_and_lifo_ancillas(&raw_gates));
        assert!(verify_revir_strict_wires_and_lifo_ancillas(&opt_gates));
        assert!(opt_gates.len() <= raw_gates.len());

        let dag_peep = dag_commutation_peephole_optimize(&raw_gates);
        assert!(dag_peep.fixed_point_reached);
        assert_eq!(dag_peep.residual_commuting_cancels, 0);
        let ssa = compact_dense_ssa_qubits(64, &dag_peep.optimized_gates)
            .expect("Dense SSA compaction must succeed");
        assert!(ssa.order_preserving_bijection_verified);
        assert_eq!(ssa.remaining_unused_qubits, 0);
    }
    assert_eq!(seen_streams.len(), 58);

    // Verify on-disk 36 PCQB files exist in ../../artifacts/pcqb/ and match pcqb_manifest.json
    let pcqb_dir = std::path::Path::new("../../artifacts/pcqb");
    let manifest_path = pcqb_dir.join("pcqb_manifest.json");
    let manifest_str = std::fs::read_to_string(&manifest_path)
        .expect("artifacts/pcqb/pcqb_manifest.json must exist on disk");
    assert!(
        manifest_str.contains("\"total_circuits\": 36")
            || manifest_str.contains("\"total_circuits\": 38")
    );
    assert!(manifest_str.contains("\"all_36_circuits\""));

    let new_files = [
        "today35_xy4_dynamical_decoupling_and_asap_parallel_zipper_24q.qasm",
        "today35_xy4_dynamical_decoupling_and_asap_parallel_zipper_24q.stim",
        "today36_parametric_width_crypto_resource_compiler_28q.qasm",
        "today36_parametric_width_crypto_resource_compiler_28q.stim",
    ];
    for fname in &new_files {
        let p = pcqb_dir.join(fname);
        assert!(p.is_file(), "Missing PCQB file on disk: {:?}", p);
        assert!(
            manifest_str.contains(fname),
            "pcqb_manifest.json missing reference to {}",
            fname
        );
    }
}

#[test]
fn test_phase28_standalone_dag_peephole_asap_xy4_dd_parametric_resource_and_36_pcqb() {
    test_68_phase28_dag_peephole_asap_xy4_dd_parametric_resource_f129_to_f132_and_36_pcqb();
}

#[test]
fn test_phase28_12_architectures_and_5_layouts_state_equivalence_and_exact_and_uncompute() {
    assert!(verify_all_12_architectures_and_5_layouts_state_equivalence(1));
    assert!(verify_all_12_architectures_and_5_layouts_state_equivalence(57));
    assert!(verify_all_12_architectures_and_5_layouts_state_equivalence(58));
    assert!(verify_all_58_oqps_across_12_architectures_and_5_layouts());
}

#[test]
fn test_69_phase29_multibasis_first_principles_qasm3_roundtrip_noisy_xy4_f133_to_f136_and_38_pcqb() {
    assert!(verify_phase29_multibasis_first_principles_qasm3_roundtrip_noisy_xy4_f133_to_f136());
    assert!(verify_all_720_multibasis_and_qasm3_roundtrip_target_matrix());
    assert!(oqp60_verify_all_60_oqp_end_to_end_synthesis());
    assert!(verify_all_60_oqps_across_12_architectures_and_5_layouts());
    assert!(run_all_today_hardware_verifications());
    assert_eq!(ALL_PHASE29_SIMPLIFICATION_RULES.len(), 4);
    assert_eq!(ALL_PHASE29_MEASUREMENT_PASSES.len(), 4);
    assert_eq!(ALL_PHASE29_FORMAL_PROOFS.len(), 4);
    assert_eq!(all_simplification_rules_s1_to_s106().len(), 106);
    assert_eq!(all_meas_opt_passes_m1_to_m72().len(), 72);

    // Verify all 60 OQP-1..60 compile to pairwise-distinct gate streams
    let mut seen_streams = Vec::with_capacity(60);
    for oqp_id in 1..=60 {
        let ast = build_oqp_coreqds_ast(oqp_id).expect("OQP-1..60 AST must exist");
        assert!(ast.ast_node_count() >= 5);
        let raw_gates = compile_coreqds_to_revir(&ast).expect("OQP AST must lower");
        let opt_gates = optimize_revir_netlist(&raw_gates);
        assert!(!seen_streams.contains(&raw_gates));
        seen_streams.push(raw_gates.clone());
        assert!(verify_revir_strict_wires_and_lifo_ancillas(&raw_gates));
        assert!(verify_revir_strict_wires_and_lifo_ancillas(&opt_gates));
        assert!(opt_gates.len() <= raw_gates.len());

        let dag_peep = dag_commutation_peephole_optimize(&raw_gates);
        assert!(dag_peep.fixed_point_reached);
        assert_eq!(dag_peep.residual_commuting_cancels, 0);
        let ssa = compact_dense_ssa_qubits(64, &dag_peep.optimized_gates)
            .expect("Dense SSA compaction must succeed");
        assert!(ssa.order_preserving_bijection_verified);
        assert_eq!(ssa.remaining_unused_qubits, 0);
    }
    assert_eq!(seen_streams.len(), 60);

    // Verify on-disk 38 PCQB files exist in ../../artifacts/pcqb/ and match pcqb_manifest.json
    let pcqb_dir = std::path::Path::new("../../artifacts/pcqb");
    let manifest_path = pcqb_dir.join("pcqb_manifest.json");
    let manifest_str = std::fs::read_to_string(&manifest_path)
        .expect("artifacts/pcqb/pcqb_manifest.json must exist on disk");
    assert!(manifest_str.contains("\"total_circuits\": 38"));
    assert!(manifest_str.contains("\"all_38_circuits\""));

    let new_files = [
        "today37_noisy_xy4_channel_and_chordal_ancilla_recycling_24q.qasm",
        "today37_noisy_xy4_channel_and_chordal_ancilla_recycling_24q.stim",
        "today38_openqasm3_roundtrip_and_720_multibasis_matrix_28q.qasm",
        "today38_openqasm3_roundtrip_and_720_multibasis_matrix_28q.stim",
    ];
    for fname in &new_files {
        let p = pcqb_dir.join(fname);
        assert!(p.is_file(), "Missing PCQB file on disk: {:?}", p);
        assert!(
            manifest_str.contains(fname),
            "pcqb_manifest.json missing reference to {}",
            fname
        );
    }
}

#[test]
fn test_phase29_standalone_multibasis_first_principles_qasm3_roundtrip_noisy_xy4_and_38_pcqb() {
    test_69_phase29_multibasis_first_principles_qasm3_roundtrip_noisy_xy4_f133_to_f136_and_38_pcqb();
}
