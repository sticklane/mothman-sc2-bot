//! Open Quantum Problems (`OQP-1..60`, `60 × 12 = 720` compilation cells), including:
//! - **`OQP-57`**: Idle-Spine XY4 Dynamical Decoupling & ASAP Parallel Zipper Scheduler (`Pass M65/M66`, `QDS-43`).
//! - **`OQP-58`**: Parametric-Width Cryptographic & Scientific Resource Compiler (`Pass M68`).
//! - **`OQP-59`**: Noisy XY4 Channel Suppression & Chordal Live-Range Ancilla Recycling Zipper (`Pass M72`, `QDS-44`, `TODAY-37`).
//! - **`OQP-60`**: OpenQASM 3.0 Round-Trip Verified 720-Cell Multi-Basis Matrix & First-Principles N-Bit AST Compiler (`Passes M69–M71`, `TODAY-38`).

pub use crate::today_hardware::{
    build_oqp_coreqds_ast, export_today35_xy4_dynamical_decoupling_idle_spine_qasm3,
    export_today36_parametric_width_resource_slice_qasm3,
    export_today37_noisy_xy4_channel_and_chordal_ancilla_recycling_qasm3,
    export_today38_openqasm3_roundtrip_and_720_multibasis_matrix_qasm3,
    oqp58_verify_all_58_oqp_end_to_end_synthesis,
    oqp60_verify_all_60_oqp_end_to_end_synthesis,
    verify_all_58_oqps_across_12_architectures_and_5_layouts,
    verify_all_60_oqps_across_12_architectures_and_5_layouts,
    verify_all_696_dag_peephole_and_asap_dd_target_matrix,
    verify_all_720_multibasis_and_qasm3_roundtrip_target_matrix,
    Today35Xy4DynamicalDecouplingIdleSpineSpec, Today36ParametricWidthResourceSliceSpec,
    Today37NoisyXy4ChannelAndChordalAncillaRecyclingSpec,
    Today38OpenQasm3RoundtripAnd720MultibasisMatrixSpec,
};

/// Total number of formalized Open Quantum Problems (`OQP-1..60`).
pub const TOTAL_OQP_COUNT: usize = 60;

/// Total number of `(OQP × ExecutionRegime × QuantumMachineType)` compilation cells (`60 × 3 × 4 = 720`).
pub const TOTAL_OQP_TARGET_MATRIX_CELLS: usize = 720;

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_oqp57_to_oqp60_and_full_720_matrix() {
        assert_eq!(TOTAL_OQP_COUNT, 60);
        assert_eq!(TOTAL_OQP_TARGET_MATRIX_CELLS, 720);
        assert!(build_oqp_coreqds_ast(57).is_some());
        assert!(build_oqp_coreqds_ast(58).is_some());
        assert!(build_oqp_coreqds_ast(59).is_some());
        assert!(build_oqp_coreqds_ast(60).is_some());
        assert!(build_oqp_coreqds_ast(61).is_none());
        assert!(oqp60_verify_all_60_oqp_end_to_end_synthesis());
        assert!(verify_all_720_multibasis_and_qasm3_roundtrip_target_matrix());
    }
}
