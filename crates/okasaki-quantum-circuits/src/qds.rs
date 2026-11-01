//! Quantum Data Structures (`QDS-1..44`), including Phase 28 `QDS-43`
//! ([`DynamicalDecouplingIdleSpineZipper`] / [`Qds43DynamicalDecouplingIdleSpineZipper`])
//! and Phase 29 `QDS-44` ([`LiveRangeChordalAncillaRecyclingZipper`] /
//! [`Qds44LiveRangeChordalAncillaRecyclingZipper`]).

pub use crate::today_hardware::{
    short_last_multichannel_reserve_audit, synthesize_qds41_distilled_epr_photonic_deque_zipper,
    synthesize_qds43_dynamical_decoupling_idle_spine_zipper,
    synthesize_qds44_live_range_chordal_ancilla_recycling_zipper,
    DynamicalDecouplingIdleSpineZipper, LiveRangeChordalAncillaRecyclingZipper,
    Qds40LakefillMinimalKernelContainer, Qds41DistilledEprPhotonicDequeZipper,
    Qds42ShortLastMultichannelReserveDeque, Qds43DynamicalDecouplingIdleSpineZipper,
    Qds44LiveRangeChordalAncillaRecyclingZipper,
};

/// Total number of formalized Okasaki Quantum Data Structures (`QDS-1..44`).
pub const TOTAL_FORMALIZED_QDS_COUNT: usize = 44;

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_qds43_and_qds44_dynamical_decoupling_and_chordal_ancilla_recycling_zippers() {
        assert_eq!(TOTAL_FORMALIZED_QDS_COUNT, 44);
        let zipper43 =
            synthesize_qds43_dynamical_decoupling_idle_spine_zipper(3, &[0, 1, 2, 4, 5], 1_240, 50)
                .expect("valid QDS-43 XY4 idle-spine zipper");
        assert_eq!(zipper43.xy4_interpulse_tau_ns, 310);
        assert_eq!(zipper43.xy4_pulse_axes, ["X", "Y", "X", "Y"]);
        assert_eq!(zipper43.total_dd_pulses_emitted, 20);
        assert_eq!(zipper43.signed_dwell_sum_ns, 0);
        assert_eq!(zipper43.net_static_dephasing_mrad, 0);
        assert!(zipper43.refocusing_verified);

        let zipper44 =
            synthesize_qds44_live_range_chordal_ancilla_recycling_zipper(&[8, 6, 8, 4])
                .expect("valid QDS-44 chordal live-range ancilla recycling zipper");
        assert_eq!(zipper44.unrecycled_sum_ancilla_width, 26);
        assert_eq!(zipper44.chordal_recycled_peak_ancilla_width, 8);
        assert_eq!(zipper44.ancilla_qubits_saved, 18);
        assert!(zipper44.lifo_clean_reset_between_epochs_verified);
        assert!(zipper44.chordal_coloring_optimal_verified);
    }
}
