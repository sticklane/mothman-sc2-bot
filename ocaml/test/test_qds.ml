(******************************************************************************)
(* test_qds.ml                                                                *)
(* ========================================================================== *)
(* Comprehensive OCaml unit test suite for Phase 8: Today-Available Quantum   *)
(* Hardware Compilation (`today_hardware.ml`) and Simplification Rules        *)
(* `S17–S20` (`simplify.ml`).                                                 *)
(******************************************************************************)

open Okasaki_qds.Lib

let assert_check (label : string) (cond : bool) : unit =
  if cond then
    Printf.printf "  [PASS] %s\n" label
  else begin
    Printf.printf "  [FAIL] %s\n" label;
    exit 1
  end

let () =
  Printf.printf "======================================================================\n";
  Printf.printf "Okasaki Quantum Data Structures — OCaml Phase 8 TodayHardware & S17-S20\n";
  Printf.printf "======================================================================\n";

  (* 1. Verify S1..S20, 6 MeasKinds, 5 MeasOptPasses *)
  assert_check "SimplificationRules S1..S20 count == 20"
    (List.length all_simplification_rules_s1_to_s20 = 20);
  assert_check "MeasKind 6-kind taxonomy count == 6"
    (List.length all_meas_kinds = 6);
  assert_check "MeasOptPass M1..M5 count == 5"
    (List.length all_meas_opt_passes = 5);

  (* 2. Verify all 4 Calibrated 2025-2026 Hardware Profiles *)
  let willow = get_today_hardware_spec GoogleWillow105 in
  let heron  = get_today_hardware_spec IBMHeronR2_156 in
  let quant  = get_today_hardware_spec QuantinuumH2_56 in
  let na     = get_today_hardware_spec BluvsteinNeutralAtom in
  assert_check "GoogleWillow105 calibrated (105Q, epsCZ=0.0033, epsMeas=0.0077)"
    (willow.ths_physical_qubits = 105 && willow.ths_eps_2q = 0.0033 && willow.ths_eps_meas = 0.0077);
  assert_check "IBMHeronR2_156 calibrated (156Q, epsCZ=0.0015, epsMeas=0.0085)"
    (heron.ths_physical_qubits = 156 && heron.ths_eps_2q = 0.0015 && heron.ths_eps_meas = 0.0085);
  assert_check "QuantinuumH2_56 calibrated (56Q, 4 zones, eps2Q=0.0006, epsMeas=0.00033)"
    (quant.ths_physical_qubits = 56 && quant.ths_zones = 4 && quant.ths_eps_2q = 0.0006 && quant.ths_eps_meas = 0.00033);
  assert_check "BluvsteinNeutralAtom calibrated (3000Q phys / 48L, epsCZ=0.0020, epsCCZ=0.0045)"
    (na.ths_physical_qubits = 3000 && na.ths_logical_qubits = 48 && na.ths_eps_2q = 0.0020 && na.ths_eps_3q = 0.0045);

  (* 3. Verify Exact 8-State RCCX Relative-Phase Cancellation (S17 & F29) *)
  let (rccx_ok1, err1) = verify_rccx_phase_cancel (Float.pi /. 3.0) in
  let (rccx_ok2, err2) = verify_rccx_phase_cancel 1.789 in
  assert_check (Printf.sprintf "verify_rccx_phase_cancel exact 8-state simulation (maxErr=%g)" (Float.max err1 err2))
    (rccx_ok1 && rccx_ok2 && verify_f29_unpaired_rccx_phase_leak_rejected ());

  (* 4. Verify S17..S20 Rewrite Passes & Guards F29..F32 *)
  let raw_circ = [
    Prim_AndCompute { ctrl1 = 0; ctrl2 = 1; tgt = 3 };
    Prim_CNOT       { ctrl = 3; tgt = 2 };
    Prim_RZ         { wire = 2; phi = 0.625 };
    Prim_CNOT       { ctrl = 3; tgt = 2 };
    Prim_HMR_CZ     { pebble = 3; ctrl1 = 0; ctrl2 = 1 };
    Prim_CSWAP      { ctrl = 0; swap1 = 1; swap2 = 2 };
    Prim_RZ         { wire = 0; phi = 0.25 };
    Prim_VirtualRZ  { wire = 0; phi = 0.50 };
    Prim_Z          0;
  ] in
  let s17_circ = rewrite_s17_rccx_uncompute_phase_cancel 0.0033 0.0077 raw_circ in
  let (s17_balanced, _) = verify_s17_balanced_rccx_pairs s17_circ in
  assert_check "S17 rewrites AndCompute + HMR_CZ into measurement-free RCCX + RCCXDag (0 MCMR)"
    (count_mid_circuit_meas s17_circ = 0 && s17_balanced);

  let s18_circ = rewrite_s18_neutral_atom_cswap_collapse raw_circ in
  assert_check "S18 collapses CSWAP into 1 NativeCCZ + 1 NativeISWAP pulse"
    (count_native_ccz s18_circ = 1 && count_native_iswap s18_circ = 1 && count_cswaps s18_circ = 0);

  let s19_circ = rewrite_s19_virtual_rz_collapse raw_circ in
  assert_check "S19 collapses 3 consecutive Z-axis rotations into 1 VirtualRZ frame update"
    (count_virtual_rz_gates s19_circ = 1);

  let s20_circ = rewrite_s20_quantinuum_rzz_kickback raw_circ in
  assert_check "S20 collapses CNOT * RZ(phi) * CNOT into 1 native RZZ(phi) entangler"
    (count_rzz_gates s20_circ = 1);

  (* 5. Verify compute_survival_grade Mode Selection & Quantinuum 52Q -> 28Q Compression *)
  let sg_willow = compute_survival_grade GoogleWillow105      52 raw_circ in
  let sg_heron  = compute_survival_grade IBMHeronR2_156       52 raw_circ in
  let sg_na     = compute_survival_grade BluvsteinNeutralAtom 52 raw_circ in
  let sg_quant  = compute_survival_grade QuantinuumH2_56      52 (raw_circ @ [ Prim_MCMR { wire = 3; zone_id = 0 } ]) in
  assert_check "compute_survival_grade selects UnitaryRCCXMode (0 MCMR) on Willow & Heron R2"
    (sg_willow.sg_compile_mode = UnitaryRCCXMode && sg_willow.sg_num_mcmr = 0
     && sg_heron.sg_compile_mode = UnitaryRCCXMode && sg_heron.sg_num_mcmr = 0);
  assert_check "compute_survival_grade selects NativeRydbergCCZMode on BluvsteinNeutralAtom"
    (sg_na.sg_compile_mode = NativeRydbergCCZMode && sg_na.sg_num_mcmr = 0 && sg_na.sg_num_3q_gates = 1);
  assert_check "compute_survival_grade selects Batch4MCMRReuseMode (52Q -> 28Q) on QuantinuumH2_56"
    (sg_quant.sg_compile_mode = Batch4MCMRReuseMode && sg_quant.sg_physical_qubits = 28);

  (* 6. Verify Multi-Zone ZipperCut Shuttling Scheduler & Fix F30 *)
  let clean_zone_wires = [
    { zws_wire_id = 0; zws_is_active_focus = true;  zws_is_dirty_ancilla = false; zws_target_zone = EntanglingZone };
    { zws_wire_id = 1; zws_is_active_focus = true;  zws_is_dirty_ancilla = false; zws_target_zone = EntanglingZone };
    { zws_wire_id = 2; zws_is_active_focus = false; zws_is_dirty_ancilla = false; zws_target_zone = StorageZone };
  ] in
  let dirty_zone_wires = [
    { zws_wire_id = 0; zws_is_active_focus = true;  zws_is_dirty_ancilla = false; zws_target_zone = EntanglingZone };
    { zws_wire_id = 2; zws_is_active_focus = false; zws_is_dirty_ancilla = true;  zws_target_zone = StorageZone };
  ] in
  assert_check "schedule_multi_zone_zipper accepts clean StorageZone & rejects dirty ancilla leak (F30)"
    (match (schedule_multi_zone_zipper 4 clean_zone_wires, schedule_multi_zone_zipper 4 dirty_zone_wires) with
     | (Ok s, Error _) -> s.mzz_verified_zero_storage_leak && (s.mzz_dirty_ancillas_in_storage = 0)
     | _ -> false);

  (* 7. Verify 3-Tier Multi-Dialect Typed IR & 5 Today-Executable Benchmarks (including 506 ns FPGA loop) *)
  assert_check "3-Tier IR: Tier 1 (hl_qds_ir) & Tier 2 (ml_rev_ir) 100% shared; diverge only at Tier 3 (ll_machine_isa)"
    (verify_shared_tier1_tier2_diverge_at_tier3 ());
  assert_check "Today-Executable Benchmarks (DQI BCH(7,4,3), BCH(15,7,5), K3, Braun QROAM 8:1, 506 ns FPGA loop)"
    (verify_today_executable_benchmarks ());

  (* 8. Verify Phase 9: Multi-Layer IR Evaluators, Intra-Layer Optimizers (Tier 1-3) & 8-Target Differential Testing (F33-F36) *)
  assert_check "F33: Tier 1 Intra-Layer Diff (eval_tier1_hl_qds (optimize_tier1_hl_qds p) == eval_tier1_hl_qds p & F33 caught)"
    (verify_f33_tier1_intra_layer_diff ());
  assert_check "F34: Tier 1 -> Tier 2 Commutativity Square (eval_tier2_ml_rev_ir (lower_tier1_to_tier2 (optimize_tier1_hl_qds p)) == eval_tier1_hl_qds p)"
    (verify_f34_tier1_to_tier2_commutativity ());
  assert_check "F35: Tier 2 Delayed-Uncomputation Region Fusion (same controls fused, mismatched controls F35 rejected)"
    (verify_f35_tier2_delayed_uncompute_region_fusion ());
  assert_check "F36: 8-Target End-to-End Differential Compiler Testing Suite (100% bitboard + phase-polynomial agreement)"
    (verify_f36_eight_target_end_to_end_compiler_diff ());
  assert_check "Master Phase 9 Multi-Layer Compiler Differential Suite (verify_multi_layer_compiler_diff_f33_to_f36)"
    (verify_multi_layer_compiler_diff_f33_to_f36 ());

  (* 9. Verify Phase 10: Hardware-Physical Soundness Extensions (F37-F40, M6-M7, synthesize_code_distance_and_phys_q) *)
  assert_check "F37: Spatial Rydberg blockade (dist >= d_min) & QCCD zone capacity (z2q_a + z2q_b <= c_zone)"
    (check_f37_spatial_par [0; 1] [2; 3] 12 8 2 2 4
     && not (check_f37_spatial_par [0; 1] [2; 3] 5 8 2 2 4)
     && not (check_f37_spatial_par [0; 1] [2; 3] 12 8 3 2 4));
  assert_check "F38 & Pass M6: Twisted Pauli frame flush before non-Clifford CCX & RZZ angle conjugation"
    (check_f38_non_clifford_frame (pass_m6_flush_frame FrameTwistedX)
     && not (check_f38_non_clifford_frame FrameTwistedX)
     && fst (pass_m6_conjugate_rzz FrameTwistedX 0.75) = -0.75);
  assert_check "F39 & Pass M5: SubspaceModality leakage guard & heralded erasure discharge"
    (check_f39_subspace_clean (pass_m5_heralded_erasure_discharge NeedsErasureHerald)
     && not (check_f39_subspace_clean NeedsErasureHerald));
  assert_check "F40 & Pass M7: DDModality asymmetric idle XY4 dynamical decoupling insertion"
    (check_f40_idle_branch_dd 650 10000 (pass_m7_insert_xy4 650 10000 UnprotectedIdle)
     && not (check_f40_idle_branch_dd 650 10000 UnprotectedIdle)
     && xy4_first_order_phase_residual 17 25 = 0);
  assert_check "Theorem 26E & Table 6F: synthesize_code_distance_and_phys_q across Regimes 0..5 (20M -> 2.52M -> 586K -> 344K -> 143K -> 9.5K)"
    (List.map (fun r -> snd (synthesize_code_distance_and_phys_q r)) all_gap_closure_regimes
       = [20000000; 2523932; 586109; 344304; 142848; 9504]
     && verify_phase10_f37_to_f40_and_gap ());

  (* 10. Verify Phase 11: Next-Frontier Ideas (F41-F44, S21-S24, Pass M8 SIMD QROAM, PCQB Exporters) *)
  assert_check "S21 & F41: NoiseBiasModality (ZBiasPreserving vs BiasBreaking) & Cat-Qubit 22Q/logical at d_Z=11"
    (check_f41_bias_preserving_gate ZBiasPreserving ZBiasPreserving
     && not (check_f41_bias_preserving_gate ZBiasPreserving BiasBreaking)
     && cat_qubit_phys_qubits_per_logical 11 = 22);
  assert_check "S22 & F42: ZipperSeamQuasiProbCut (k_seam <= 2, 81x sampling overhead, 178q DQI BCH(127) -> 28q)"
    ((partition_dqi_bch127_with_zipper_cut 2).zsq_within_budget
     && (partition_dqi_bch127_with_zipper_cut 2).zsq_sampling_overhead_gamma2 = 81
     && not (check_f42_zipper_seam_cut_width 3));
  assert_check "S23 & F43: STAR direct phase-polynomial 45x T-gate saving & Speculative Cultivation O(1) RCCX_Dag rollback"
    (star_direct_rotation_t_gate_saving 4 = (180, 4, 45)
     && check_f43_speculative_cultivation_rollback false true
     && not (check_f43_speculative_cultivation_rollback false false));
  assert_check "S24, Pass M8 & F44: Swiss-Cheese Braun defect remap + Vectorized SIMD Multi-Query QROAM batching"
    (swiss_cheese_braun_defect_remap 10 3 7 = (true, 10, 10)
     && pass_m8_vectorized_simd_qroam_batch 8 256 false = Some (2048, 256, 8)
     && pass_m8_vectorized_simd_qroam_batch 8 256 true  = None);
  assert_check "PCQB Exporters: export_pcqb_openqasm3 & export_pcqb_stim for TODAY-1..6 & verify_phase11_f41_to_f44_and_pcqb"
    (String.length (export_pcqb_openqasm3 1) > 0 && String.length (export_pcqb_stim 1) > 0 && verify_phase11_f41_to_f44_and_pcqb ());

  (* 11. Verify Phase 12: QDS-14..16, OQP-11..14, F45-F48, S25-S28, Passes M9-M10 *)
  assert_check "S1-S28 & M1-M10 cardinalities (28 simplification rules, 10 measurement passes)"
    (List.length all_simplification_rules_s1_to_s28 = 28 && List.length all_meas_opt_passes_m1_to_m10 = 10);
  assert_check "Phase 12 F45-F48, QDS-14..16, OQP-11..14, M9-M10 verification suite"
    (verify_phase12_f45_to_f48_qds14_to_16_and_oqp11_to_14 ());

  (* 12. Verify Phase 13: Root-Cause Gap Meta-Auditor (GAP-1..4), QDS-17..19, OQP-15..18, F49-F54, S29-S34, Passes M11-M14 *)
  assert_check "S1-S34 & M1-M14 cardinalities (34 simplification rules, 14 measurement passes)"
    (List.length all_simplification_rules_s1_to_s34 = 34 && List.length all_meas_opt_passes_m1_to_m14 = 14);
  assert_check "Phase 13 F49-F54, QDS-17..19, OQP-15..18, M11-M14 & Root-Cause Gap Meta-Auditor verification suite"
    (verify_phase13_f49_to_f54_qds17_to_19_and_oqp15_to_18 ());

  (* 13. Verify Phase 14: Automated Problem-Discovery Engines (PDE-1..6), QDS-20..22, OQP-19..22, F55-F60, S35-S40, Passes M15-M18 *)
  assert_check "S1-S40 & M1-M18 cardinalities (40 simplification rules, 18 measurement passes)"
    (List.length all_simplification_rules_s1_to_s40 = 40 && List.length all_meas_opt_passes_m1_to_m18 = 18);
  assert_check "Phase 14 F55-F60, PDE-1..6, QDS-20..22, OQP-19..22, M15-M18 verification suite"
    (verify_phase14_f55_to_f60_pde1_to_6_qds20_to_22_and_oqp19_to_22 ());

  (* 14. Verify Phase 15: QDS-23..25, OQP-23..26, F61-F66, S41-S46, Passes M19-M22 *)
  assert_check "S1-S46 & M1-M22 cardinalities (46 simplification rules, 22 measurement passes)"
    (List.length all_simplification_rules_s1_to_s46 = 46 && List.length all_meas_opt_passes_m1_to_m22 = 22);
  assert_check "Phase 15 F61-F66, QDS-23..25, OQP-23..26, M19-M22 verification suite"
    (verify_phase15_f61_to_f66_qds23_to_25_and_oqp23_to_26 ());

  (* 15. Verify Phase 16: CoreQDS, 3-Loop Privilege-Tier Boundary, QDS-26..28, OQP-27..30, F67-F72, S47-S52, Passes M23-M26 *)
  assert_check "S1-S52 & M1-M26 cardinalities (52 simplification rules, 26 measurement passes)"
    (List.length all_simplification_rules_s1_to_s52 = 52 && List.length all_meas_opt_passes_m1_to_m26 = 26);
  assert_check "Phase 16 F67-F72, CoreQDS, 3-Loop Privilege Tier, QDS-26..28, OQP-27..30, M23-M26 verification suite"
    (verify_phase16_f67_to_f72_coreqds_3loop_qds26_to_28_and_oqp27_to_30 ());

  (* 16. Verify Phase 17: High-Level Quantum Language Literature Synthesis (Cobble, Spire, QCM, Qunity, Qwerty, Guppy, Yang & Yuan), QDS-29..31, OQP-31..34, F73-F78, S53-S58, Passes M27-M30 *)
  assert_check "S1-S58 & M1-M30 cardinalities (58 simplification rules, 30 measurement passes)"
    (List.length all_simplification_rules_s1_to_s58 = 58 && List.length all_meas_opt_passes_m1_to_m30 = 30);
  assert_check "Phase 17 F73-F78, Cobble, Spire, QCM, Qunity, Qwerty/ASDF, Guppy, Yang & Yuan, QDS-29..31, OQP-31..34, M27-M30 verification suite"
    (verify_phase17_f73_to_f78_cobble_spire_qcm_qunity_qwerty_qds29_to_31_and_oqp31_to_34 ());

  (* 17. Verify Phase 18: Constructive IR-to-IR Transformations, S17/S19/S20 Guard Fixes, HUGR, Twist, Tower, Bocher/Benes, QDS-32..34, OQP-35..38, F79-F84, S59-S64, Passes M31-M34 *)
  assert_check "S1-S64 & M1-M34 cardinalities (64 simplification rules, 34 measurement passes)"
    (List.length all_simplification_rules_s1_to_s64 = 64 && List.length all_meas_opt_passes_m1_to_m34 = 34);
  assert_check "Phase 18 F79-F84, Constructive IR-to-IR, HUGR, Twist, Tower, Bocher/Benes, QDS-32..34, OQP-35..38, M31-M34 verification suite"
    (verify_phase18_f79_to_f84_constructive_ir_hugr_twist_tower_qds32_to_34_and_oqp35_to_38 ());

  (* 18. Verify Phase 19: End-to-End CoreQDS Lowering Compiler, All 42 OQPs, QDS-35..37, OQP-39..42, F85-F90, S65-S70, Passes M35-M38 *)
  assert_check "S1-S70 & M1-M38 cardinalities (70 simplification rules, 38 measurement passes)"
    (List.length all_simplification_rules_s1_to_s70 = 70
     && List.length all_meas_opt_passes_m1_to_m38 = 38
     && List.length all_core_qds_combinators_13 = 13);
  assert_check "Phase 19 F85-F90, End-to-End CoreQDS Lowering Compiler, All 42 OQPs, QDS-35..37, OQP-39..42, TODAY-21/22, M35-M38 verification suite"
    (verify_phase19_f85_to_f90_end_to_end_coreqds_lowering_all_oqp1_to_42 ()
     && oqp42_verify_all_42_oqp_end_to_end_synthesis ());

  (* 19. Verify Phase 20: CoreQDS 2.0 Complete Language Upgrade (20-Constructor AST, QFreeExpr, S71-S74, M39-M40, F91-F94, CE-1..CE-10) *)
  assert_check "S1-S74 & M1-M40 cardinalities (74 simplification rules, 40 measurement passes)"
    (List.length all_simplification_rules_s1_to_s74 = 74
     && List.length all_meas_opt_passes_m1_to_m40 = 40);
  assert_check "Phase 20 F91-F94, CoreQDS 2.0 20-Constructor AST, QFreeExpr Reversible Compiler, CE-1..CE-10 Counterexample Rejection Suite"
    (verify_phase20_coreqds2_complete_language_f91_to_f94 ()
     && verify_forbidden_coreqds_counterexamples_ce1_to_ce10 ());

  (* 20. Verify Phase 21: Translation-Validated & Provably Optimal CoreQDS 2.0 Circuit Compilation & 12-Target 3x4 Multi-Architecture Backend Matrix (S75-S78, M41-M44, F95-F100, OQP-43..46, TODAY-23..24) *)
  assert_check "S1-S78 & M1-M44 cardinalities (78 simplification rules, 44 measurement passes)"
    (List.length all_simplification_rules_s1_to_s78 = 78
     && List.length all_meas_opt_passes_m1_to_m44 = 44);
  assert_check "Phase 21 F95-F100, OQP-1..46 End-to-End Synthesis, KAK SU(4) & Multiplicative-Complexity Optimality, 12-Target 3x4 Matrix, TODAY-23/24"
    (verify_phase21_translation_validated_optimal_coreqds_f95_to_f100 ()
     && oqp46_verify_all_46_oqp_end_to_end_synthesis ()
     && verify_all_12_target_architectures_matrix (build_oqp_coreqds_ast 43));

  (* 21. Verify Phase 22: Next-Generation SOTA Compiler (Exact Z[1/sqrt(2),i] Unitary Equivalence, Non-Local Phase-Polynomial T-par & GF(2) CNOT Synthesis, Explicit Coupling-Graph Routing, Bit-Accurate Braun Tree QDS-38, Stim DEM Distance Verifier, S79-S82, M45-M48, F101-F106, OQP-47..48, TODAY-25..26) *)
  assert_check "S1-S82 & M1-M48 cardinalities (82 simplification rules, 48 measurement passes)"
    (List.length all_simplification_rules_s1_to_s82 = 82
     && List.length all_meas_opt_passes_m1_to_m48 = 48);
  assert_check "Phase 22 F101-F106, OQP-1..48 End-to-End Synthesis, Exact Dyadic Unitary Verifier, T-par & GF(2) CNOT Synthesis, SABRE Coupling-Graph Routing, QDS-38 Braun Lens, Stim DEM Distance, TODAY-25/26"
    (verify_phase22_sota_exact_dyadic_tpar_sabre_stim_f101_to_f106 ()
     && oqp48_verify_all_48_oqp_end_to_end_synthesis ()
     && verify_qds38_braun_tree_lens_laws (build_qds38_braun_tree_layout 3 2));

  (* 22. Verify Phase 23: Multi-Shot Gidney MBU, TeleGate Distributed Cutting, Native ISA Rebasing & 600-Cell Matrix (S83-S86, M49-M52, F107-F112, OQP-49..50, QDS-39, TODAY-27..28) *)
  assert_check "S1-S86 & M1-M52 cardinalities (86 simplification rules, 52 measurement passes)"
    (List.length all_simplification_rules_s1_to_s86 = 86
     && List.length all_meas_opt_passes_m1_to_m52 = 52);
  assert_check "Phase 23 F107-F112, OQP-1..50 End-to-End Synthesis, Multi-Shot Gidney MBU, TeleGate Cat-Entangler, Native ISA Rebasing, QDS-39 Distributed Braun Forest, 600-Cell Matrix, TODAY-27/28"
    (verify_phase23_gidney_mbu_telegate_native_isa_600_matrix_f107_to_f112 ()
     && oqp50_verify_all_50_oqp_end_to_end_synthesis ()
     && verify_all_600_oqp_target_arch_matrix ()
     && verify_qds39_distributed_braun_forest_lens_laws (build_qds39_distributed_braun_forest 3 2 2));

  (* 23. Verify Phase 24: ZX-Calculus Spider Fusion & Pauli-Web 48q, Ross-Selinger GridSynth, Lakefill Minimal 6-Constructor Kernel IR & 624-Cell Matrix (S87-S90, M53-M56, F113-F118, OQP-51..52, QDS-40, TODAY-29..30) *)
  assert_check "S1-S90 & M1-M56 cardinalities (90 simplification rules, 56 measurement passes)"
    (List.length all_simplification_rules_s1_to_s90 = 90
     && List.length all_meas_opt_passes_m1_to_m56 = 56);
  assert_check "Phase 24 F113-F118, OQP-1..52 End-to-End Synthesis, ZX Spider Fusion & Pauli-Web 48q, Ross-Selinger GridSynth, QDS-40 Lakefill Minimal 6-Constructor Kernel, 624-Cell Matrix, TODAY-29/30"
    (verify_phase24_zx_pauli_web_gridsynth_lakefill_kernel6_f113_to_f118 ()
     && oqp52_verify_all_52_oqp_end_to_end_synthesis ()
     && verify_all_624_oqp_target_arch_matrix ()
     && (match new_qds40_lakefill_minimal_kernel_container (build_oqp_coreqds_ast 52) with Ok c -> c.qds40_kernel_constructor_count = 6 | Error _ -> false));

  (* 24. Verify Phase 25: Graph-Like ZX Local Complementation (LC), Pivot & Gflow Circuit Extraction, Magic-State Cultivation + Litinski GoSC Scheduling, DEJMPS Entanglement-Distilled EPR & Photonic Fusion Deque-Zipper (QDS-41), and Proof-Carrying Compilation (PCC-Lakefill) across the 648-Cell Matrix (S91-S94, M57-M60, F119-F124, OQP-53..54, QDS-41, TODAY-31..32) *)
  assert_check "S1-S94 & M1-M60 cardinalities (94 simplification rules, 60 measurement passes)"
    (List.length all_simplification_rules_s1_to_s94 = 94
     && List.length all_meas_opt_passes_m1_to_m60 = 60);
  assert_check "Phase 25 F119-F124, OQP-1..54 End-to-End Synthesis, ZX LC/Pivot/Gflow Extraction, Magic-State Cultivation + GoSC, QDS-41 DEJMPS Photonic Deque-Zipper, 648-Cell PCC-Lakefill Matrix, TODAY-31/32"
    (verify_phase25_gflow_cultivation_dejmps_pcc_lakefill_f119_to_f124 ()
     && oqp54_verify_all_54_oqp_end_to_end_synthesis ()
     && verify_all_648_pcc_lakefill_target_matrix ()
     && (match distill_dejmps_epr_photonic_deque 10000 2 4 8 with Ok dq -> dq.qds41_distilled_bell_infidelity_ppm < dq.qds41_raw_bell_infidelity_ppm | Error _ -> false));

  (* 25. Verify Phase 27: Post-Rebase & Post-Route Involution/Commutation Peephole Optimizer, Dense 0-Gap SSA Qubit Compaction, Short-Last Multi-Channel Token-Bucket Reserve Audit (QDS-42), Bilateral Phase-Octant Z_8 Invariance, and 672-Cell Matrix (S95-S98, M61-M64, F125-F130, OQP-55..56, QDS-42, TODAY-33..34) *)
  assert_check "S1-S98 & M1-M64 cardinalities (98 simplification rules, 64 measurement passes)"
    (List.length all_simplification_rules_s1_to_s98 = 98
     && List.length all_meas_opt_passes_m1_to_m64 = 64);
  assert_check "Phase 27 F125-F130, OQP-1..56 End-to-End Synthesis, Post-Route Peephole Optimizer, Dense 0-Gap SSA Compaction, QDS-42 Short-Last Multichannel Reserve, Bilateral Phase-Octant Mod-8 Invariance, 672-Cell Matrix, TODAY-33/34"
    (verify_phase27_post_route_peephole_dense_ssa_short_last_bilateral_f125_to_f130 ()
     && oqp56_verify_all_56_oqp_end_to_end_synthesis ()
     && verify_all_672_post_route_peephole_target_matrix ()
     && (match short_last_multichannel_reserve_audit 64 128 [32; 256; 48; 512] with Ok a -> a.qds42_short_last_ordered && a.qds42_zero_starvation_verified | Error _ -> false)
     && (match bilateral_phase_octant_invariance_check [1; 7; 2; 6] [3; 5; 4; 4] 2 with Ok r -> r.bpor_octant_invariant_ok | Error _ -> false));

  (* 26. Verify Phase 28: Commutation-Aware Per-Wire DAG & Diagonal-Z Peephole Optimizer (`S99`, `M65`, `F129`), ASAP Parallel Critical-Path Scheduler & Balanced 4-Pulse XY4 Dynamical Decoupling Idle-Spine Zipper (`QDS-43`, `S100`, `M66`, `F130`, `OQP-57`, `TODAY-35`), GRH 8-Pattern Zero-Drift & 100% <=30-Line Small-Proof Audit (`S101`, `M67`, `F131`), Parametric Symbolic-Width Cryptographic & Scientific Resource Compiler (`S102`, `M68`, `F132`, `OQP-58`, `TODAY-36`), and 696-Cell + 12-Arch x 5-Layout Equivalence Matrix *)
  assert_check "S1-S102 & M1-M68 cardinalities (102 simplification rules, 68 measurement passes)"
    (List.length all_simplification_rules_s1_to_s102 = 102
     && List.length all_meas_opt_passes_m1_to_m68 = 68);
  assert_check "Phase 28 F129-F134, OQP-1..58 End-to-End Synthesis, Per-Wire DAG & Diagonal-Z Peephole Optimizer, ASAP Parallel Critical-Path & QDS-43 XY4 Idle-Spine Zipper, GRH 8-Pattern <=30-Line Audit, Parametric Symbolic-Width Resource Compiler, 696-Cell Matrix & 12-Arch x 5-Layout Equivalence, TODAY-35/36"
    (verify_phase28_dag_peephole_asap_xy4_dd_parametric_resource_f129_to_f132 ()
     && oqp58_verify_all_58_oqp_end_to_end_synthesis ()
     && verify_all_696_dag_peephole_and_asap_target_matrix ()
     && verify_all_12_architectures_and_5_layouts_state_equivalence ()
     && (match compile_parametric_width_resource FamilyEcc256 256 with Ok e -> e.pwre_logical_qubits = 1088 && e.pwre_multi_shot_halving_exact | Error _ -> false)
     && (match verify_grh_eight_pattern_zero_drift 190 28 0 0 with Ok g -> g.grh_all_eight_patterns_zero_drift | Error _ -> false));

  (* 27. Verify Phase 29: OpenQASM 3.0 / Stim Round-Trip Parser & Bitboard Equivalence (`S103`, `M69`, `F133`), Noisy Depolarizing + Amplitude/Phase-Damping Channel & XY4 DD Suppression (`S104`, `M70`, `F134`, `OQP-59`, `TODAY-37`), Chordal Ancilla-Pool Register Recycling (`QDS-44`, `S105`, `M71`, `F135`), and 720-Cell (60 OQP x 12 Arch) + 5-Basis (Z, X, Y, Bell, GHZ) Matrix (`S106`, `M72`, `F136`, `OQP-60`, `TODAY-38`) *)
  assert_check "S1-S106 & M1-M72 cardinalities (106 simplification rules, 72 measurement passes)"
    (List.length all_simplification_rules_s1_to_s106 = 106
     && List.length all_meas_opt_passes_m1_to_m72 = 72);
  assert_check "Phase 29 F133-F136, OQP-1..60 End-to-End Synthesis, OpenQASM 3.0 Round-Trip Parser, Noisy Channel & XY4 DD Suppression, QDS-44 Chordal Ancilla-Pool Recycling, 720-Cell + 5-Basis Matrix, TODAY-37/38"
    (verify_phase29_qasm3_roundtrip_noisy_xy4_chordal_recycle_720_multibasis_f133_to_f136 ()
     && oqp60_verify_all_60_oqp_end_to_end_synthesis ()
     && verify_all_720_qasm3_roundtrip_and_multibasis_target_matrix ()
     && verify_all_12_architectures_5_layouts_and_5_bases_equivalence ()
     && (match simulate_noisy_xy4_channel 4 20 8 [ RevH 0; RevCNOT (0, 1); RevX 2; RevCNOT (2, 3) ] with Ok n -> n.nxr_dd_strictly_improves_fidelity && n.nxr_trace_preserving_ok | Error _ -> false)
     && (match allocate_chordal_ancilla_pool [ (0, 3, true); (4, 7, true); (8, 11, true); (1, 5, true); (6, 10, true) ] with Ok p -> p.cap_saved_qubits >= 3 && p.cap_zero_dirty_reuse | Error _ -> false));

  let (all_ok, summary_msg) = run_all_today_hardware_verifications () in
  assert_check ("Master TodayHardware verification suite (" ^ summary_msg ^ ")") all_ok;

  Printf.printf "======================================================================\n";
  Printf.printf "ALL OCAML PHASE-8..29 TODAY-HARDWARE & F29-F136 UNIT TESTS PASSED (100%%)!\n";
  Printf.printf "======================================================================\n"
