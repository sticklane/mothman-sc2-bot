//! Phase 28 & Phase 29 Compiler Passes (`Passes M65–M72`, `S99–S106`, `Fixes F129–F136`):
//! - **Pass M65 (`S99`, `Fix F129`)**: [`dag_commutation_peephole_optimize`] & [`post_peephole_native_t_count`],
//!   plus exact syntactic/unitary adjoint `AND-UNCOMPUTE` rebasing ([`rebase_maslov_4t_and_uncompute`], `T <-> Tdg`).
//! - **Pass M66 (`S100`, `Fix F130`)**: [`compute_asap_parallel_critical_path_and_idle_dd`] computing ASAP parallel
//!   DAG critical-path latency (`parallel_critical_path_ns <= serial_gate_sum_ns`), idle spectator wait windows,
//!   and 4-pulse XY4 dynamical decoupling insertion counts.
//! - **Pass M67 (`S101`, `Fix F131`)**: [`verify_grh_eight_pattern_zero_drift`] validator across `GRH-1..8`.
//! - **Pass M68 (`S102`, `Fix F132`)**: [`compile_parametric_width_resource`] for the 5 flagship cryptographic and
//!   scientific problem families (`ECC256`, `RSA2048`, `DQI`, `AES256`, `SPHINCSPlus`).
//! - **Pass M69 (`S103`, `Fix F133`)**: [`teleport_cz_hadamard_conjugated`] & [`verify_multibasis_720_target_and_300_layout_equivalence`].
//! - **Pass M70 (`S104`, `Fix F134`)**: [`compile_first_principles_nbit_lakefill_ast`] & [`verify_grh_ten_pattern_zero_drift`].
//! - **Pass M71 (`S105`, `Fix F135`)**: [`parse_and_verify_openqasm3_roundtrip`].
//! - **Pass M72 (`S106`, `Fix F136`)**: [`simulate_noisy_z_drift_xy4_channel`] & [`synthesize_qds44_live_range_chordal_ancilla_recycling_zipper`].

pub use crate::today_hardware::{
    adjoint_lowered_rev_gate, all_meas_opt_passes_m1_to_m72, all_simplification_rules_s1_to_s106,
    check_f129_dag_commutation_peephole_and_exact_and_uncompute_safe,
    check_f130_asap_parallel_critical_path_and_qds43_xy4_dd_safe,
    check_f131_grh_eight_pattern_zero_drift_safe,
    check_f132_parametric_width_resource_and_696_matrix_safe,
    check_f133_hadamard_conjugated_cz_telegate_and_720_multibasis_safe,
    check_f134_first_principles_nbit_ast_and_grh_ten_pattern_safe,
    check_f135_openqasm3_roundtrip_parser_and_semantic_equiv_safe,
    check_f136_noisy_z_drift_xy4_channel_and_qds44_chordal_recycling_safe,
    compile_first_principles_nbit_lakefill_ast, compile_parametric_width_resource,
    compile_revir_for_arch_and_layout5, compute_asap_parallel_critical_path_and_idle_dd,
    dag_commutation_peephole_optimize, evaluate_canonical_unpermuted_quantum_state,
    evaluate_canonical_unpermuted_quantum_state_from_probe, gates_commute_in_dag,
    is_diagonal_z_gate, parse_and_verify_openqasm3_roundtrip, physical_gate_duration_ns,
    post_peephole_native_t_count, rebase_maslov_4t_and_compute, rebase_maslov_4t_and_uncompute,
    simulate_noisy_z_drift_xy4_channel, synthesize_exact_unitary_adjoint_stream,
    teleport_cz_hadamard_conjugated,
    verify_all_12_architectures_and_5_layouts_state_equivalence,
    verify_all_58_oqps_across_12_architectures_and_5_layouts,
    verify_all_60_oqps_across_12_architectures_and_5_layouts,
    verify_all_696_dag_peephole_and_asap_dd_target_matrix,
    verify_all_720_multibasis_and_qasm3_roundtrip_target_matrix,
    verify_grh_eight_pattern_zero_drift, verify_grh_ten_pattern_zero_drift,
    verify_multibasis_720_target_and_300_layout_equivalence,
    verify_phase28_dag_peephole_asap_xy4_dd_parametric_resource_f129_to_f132,
    verify_phase29_multibasis_first_principles_qasm3_roundtrip_noisy_xy4_f133_to_f136,
    AsapParallelAndIdleDdReport, CanonicalUnpermutedStateDigest, CouplingGraphLayout5,
    DagCommutationPeepholeReport, FirstPrinciplesNBitAstReport, GrhEightPatternAuditReport,
    GrhTenPatternAuditReport, Multibasis720And300EquivalenceReport, NoisyZDriftXy4ChannelReport,
    OpenQasm3RoundtripReport, ParametricProblemFamily, ParametricResourceEstimate,
    Phase28FormalProofId, Phase28MeasurementPass, Phase28SimplificationRule,
    Phase29FormalProofId, Phase29MeasurementPass, Phase29SimplificationRule,
    ALL_5_COUPLING_GRAPH_LAYOUTS, ALL_PARAMETRIC_PROBLEM_FAMILIES, ALL_PHASE28_FORMAL_PROOFS,
    ALL_PHASE28_MEASUREMENT_PASSES, ALL_PHASE28_SIMPLIFICATION_RULES, ALL_PHASE29_FORMAL_PROOFS,
    ALL_PHASE29_MEASUREMENT_PASSES, ALL_PHASE29_SIMPLIFICATION_RULES,
};

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_compiler_pass_m65_dag_commutation_peephole_and_exact_and_uncompute_adjoint() {
        assert!(check_f129_dag_commutation_peephole_and_exact_and_uncompute_safe());
        let fwd = rebase_maslov_4t_and_compute(0, 1, 2);
        let adj = rebase_maslov_4t_and_uncompute(0, 1, 2);
        assert_ne!(fwd, adj);
        let mut combined = fwd;
        combined.extend(adj);
        let opt = dag_commutation_peephole_optimize(&combined);
        assert_eq!(opt.output_gate_count, 0);
        assert_eq!(opt.post_peephole_native_t_count, 0);
    }

    #[test]
    fn test_compiler_pass_m66_asap_parallel_critical_path_and_xy4_dd() {
        assert!(check_f130_asap_parallel_critical_path_and_qds43_xy4_dd_safe());
    }

    #[test]
    fn test_compiler_pass_m67_grh_eight_pattern_zero_drift() {
        assert!(check_f131_grh_eight_pattern_zero_drift_safe());
    }

    #[test]
    fn test_compiler_pass_m68_parametric_width_resource_5_flagship_families() {
        assert!(check_f132_parametric_width_resource_and_696_matrix_safe());
    }

    #[test]
    fn test_compiler_all_12_architectures_and_5_coupling_layouts_state_equivalence() {
        assert!(verify_all_12_architectures_and_5_layouts_state_equivalence(1));
        assert!(verify_all_12_architectures_and_5_layouts_state_equivalence(57));
        assert!(verify_all_12_architectures_and_5_layouts_state_equivalence(58));
        assert!(verify_all_12_architectures_and_5_layouts_state_equivalence(59));
        assert!(verify_all_12_architectures_and_5_layouts_state_equivalence(60));
        assert!(verify_all_60_oqps_across_12_architectures_and_5_layouts());
    }

    #[test]
    fn test_compiler_passes_m69_to_m72_phase29_complete() {
        assert!(check_f133_hadamard_conjugated_cz_telegate_and_720_multibasis_safe());
        assert!(check_f134_first_principles_nbit_ast_and_grh_ten_pattern_safe());
        assert!(check_f135_openqasm3_roundtrip_parser_and_semantic_equiv_safe());
        assert!(check_f136_noisy_z_drift_xy4_channel_and_qds44_chordal_recycling_safe());
        assert!(verify_phase29_multibasis_first_principles_qasm3_roundtrip_noisy_xy4_f133_to_f136());
    }
}
