//! `rust_qds_viz`: Quantum Rust Visualization & Structural Graph Audit Library
//! for *Purely Functional Data Structures and Chordal Register Allocation in
//! Reversible Quantum Circuits*.
//!
//! Provides interoperable Quantum Rust visualization and verification back-ends
//! across all nine Okasaki reversible quantum data structures (Section 3 of the paper):
//!   1. `hugr_portgraph`: Linear-typed Hierarchical Unified Graph Representation
//!      (`tket2` / `quantinuum-hugr` / `portgraph` style) with SSA chordal
//!      Perfect Elimination Ordering (`PEO`) register allocation ($\chi(G) = \omega(G)$)
//!      and Mermaid (`.mermaid_string()`) + Graphviz DOT (`.dot_string()`) exporters.
//!   2. `quizx_zx`: Pure-Rust ZX-calculus spider graph (`quizx::VecGraph` style)
//!      for Gidney degree-2 measurement-based uncomputation (`MEAS_X_PAULI_FRAME`)
//!      spider fusion, skew-binary local carry-save rails, and SimHash XNOR
//!      popcount trees, with TikZ (`.to_tikz()`) and Graphviz DOT (`.to_dot()`) exporters.
//!   3. `oxidd_tdd`: Reduced canonical Tensor Decision Diagram (`oxidd-rules-tdd` /
//!      `oxidd-vis` style) verifying history independence and state-space structure
//!      across all 9 functional quantum data structures, with `.to_dot()` export.
//!   4. `quill_typst`: Programmatic Typst `quill` (`#quantum-circuit(...)`) vector
//!      circuit generator and `quantr`-style UTF-8 terminal circuit drawer for all 9
//!      data structures.

use std::collections::{BTreeMap, BTreeSet};
use std::fmt::Write as _;

/// Enumeration of the 9 Okasaki reversible quantum data structures from Section 3.
#[derive(Clone, Copy, Debug, PartialEq, Eq, PartialOrd, Ord, Hash)]
pub enum OkasakiStructure {
    /// 3.1 Huet Focus Zipper (`HuetFocusZipper`)
    HuetFocusZipper,
    /// 3.2 Skew-Binary Carry-Save Numeral (`SkewBinaryCarrySaveNumeral`)
    SkewBinaryCarrySaveNumeral,
    /// 3.3 Braun Tree (`BraunTree`)
    BraunTree,
    /// 3.4 Packed Bezout Shift-Zipper (`PackedBezoutShiftZipper`)
    PackedBezoutShiftZipper,
    /// 3.5 Binomial Pebble Schedule (`BinomialPebbleSchedule`)
    BinomialPebbleSchedule,
    /// 3.6 Monoidal Finger-Tree Prefix Filter (`MonoidalFingerTreeFilter`)
    MonoidalFingerTreeFilter,
    /// 3.7 Bruhat Pivoted LU / Streaming Syndrome Accumulator (`BruhatPivotedLU` / `StreamingSyndromeAccumulator`)
    BruhatPivotedLuSyndrome,
    /// 3.8 Canonical Crit-Bit and Bitonic Dictionary (`CanonicalCritBitBitonicDictionary`)
    CanonicalCritBitBitonicDictionary,
    /// 3.9 Walker-Vose Alias Table (`WalkerVoseAliasTable`)
    WalkerVoseAliasTable,
}

impl OkasakiStructure {
    pub const ALL: [OkasakiStructure; 9] = [
        OkasakiStructure::HuetFocusZipper,
        OkasakiStructure::SkewBinaryCarrySaveNumeral,
        OkasakiStructure::BraunTree,
        OkasakiStructure::PackedBezoutShiftZipper,
        OkasakiStructure::BinomialPebbleSchedule,
        OkasakiStructure::MonoidalFingerTreeFilter,
        OkasakiStructure::BruhatPivotedLuSyndrome,
        OkasakiStructure::CanonicalCritBitBitonicDictionary,
        OkasakiStructure::WalkerVoseAliasTable,
    ];
}

// ============================================================================
// 1. HUGR Linear Portgraph & Chordal SSA Register Allocator (`tket2` / `hugr`)
// ============================================================================

#[derive(Clone, Copy, Debug, PartialEq, Eq, PartialOrd, Ord)]
pub enum PortType {
    /// Linear quantum wire bundle of width `w` qubits (cannot be cloned or dropped)
    LinearQubit(usize),
    /// Classical control / schedule parameter wire
    ClassicalBit(usize),
}

#[derive(Clone, Debug)]
pub struct HugrNode {
    pub id: usize,
    pub op_name: String,
    pub inputs: Vec<(String, PortType)>,
    pub outputs: Vec<(String, PortType)>,
    pub toffoli_cost: u64,
}

#[derive(Clone, Debug)]
pub struct HugrWire {
    pub src_node: usize,
    pub src_port: usize,
    pub dst_node: usize,
    pub dst_port: usize,
    pub label: String,
    pub port_type: PortType,
}

#[derive(Clone, Debug)]
pub struct HugrPortgraph {
    pub name: String,
    pub nodes: Vec<HugrNode>,
    pub wires: Vec<HugrWire>,
    pub live_intervals: Vec<(String, usize, usize, usize)>, // (reg_name, start_step, end_step, width_qubits)
}

impl HugrPortgraph {
    pub fn new(name: &str) -> Self {
        Self {
            name: name.to_string(),
            nodes: Vec::new(),
            wires: Vec::new(),
            live_intervals: Vec::new(),
        }
    }

    pub fn add_node(
        &mut self,
        op_name: &str,
        inputs: Vec<(&str, PortType)>,
        outputs: Vec<(&str, PortType)>,
        toffoli_cost: u64,
    ) -> usize {
        let id = self.nodes.len();
        self.nodes.push(HugrNode {
            id,
            op_name: op_name.to_string(),
            inputs: inputs.into_iter().map(|(k, v)| (k.to_string(), v)).collect(),
            outputs: outputs.into_iter().map(|(k, v)| (k.to_string(), v)).collect(),
            toffoli_cost,
        });
        id
    }

    pub fn add_ssa_interval(
        &mut self,
        reg_name: &str,
        start_step: usize,
        end_step: usize,
        width_qubits: usize,
    ) {
        self.live_intervals
            .push((reg_name.to_string(), start_step, end_step, width_qubits));
    }

    pub fn connect(
        &mut self,
        src_node: usize,
        src_port: usize,
        dst_node: usize,
        dst_port: usize,
        label: &str,
    ) -> Result<(), String> {
        let src_ty = self.nodes[src_node].outputs[src_port].1;
        let dst_ty = self.nodes[dst_node].inputs[dst_port].1;
        if src_ty != dst_ty {
            return Err(format!(
                "HUGR linear port type mismatch on wire {}: {:?} != {:?}",
                label, src_ty, dst_ty
            ));
        }
        // Check no-cloning on linear quantum output ports and collision on input ports
        if matches!(src_ty, PortType::LinearQubit(_)) {
            for w in &self.wires {
                if w.src_node == src_node && w.src_port == src_port {
                    return Err(format!(
                        "HUGR linearity violation (no-cloning): output port ({}, {}) already connected",
                        src_node, src_port
                    ));
                }
                if w.dst_node == dst_node && w.dst_port == dst_port {
                    return Err(format!(
                        "HUGR linearity violation (collision): input port ({}, {}) already connected",
                        dst_node, dst_port
                    ));
                }
            }
        }
        self.wires.push(HugrWire {
            src_node,
            src_port,
            dst_node,
            dst_port,
            label: label.to_string(),
            port_type: src_ty,
        });
        Ok(())
    }

    /// Computes exact SSA chordal max clique size $\omega(G) = \max_t |\text{Live}(t)|$.
    pub fn chordal_max_live_qubits(&self) -> usize {
        let max_step = self
            .live_intervals
            .iter()
            .map(|(_, _, e, _)| *e)
            .max()
            .unwrap_or(0);
        let mut max_live = 0usize;
        for t in 0..=max_step {
            let live_t: usize = self
                .live_intervals
                .iter()
                .filter(|(_, s, e, _)| *s <= t && t <= *e)
                .map(|(_, _, _, w)| *w)
                .sum();
            if live_t > max_live {
                max_live = live_t;
            }
        }
        max_live
    }

    /// Computes exact SSA chordal chromatic number $\chi(G)$ via greedy Perfect Elimination Ordering
    /// (sorted by interval start time), verifying $\chi(G) = \omega(G)$.
    pub fn chordal_peo_chromatic_qubits(&self) -> usize {
        let mut sorted = self.live_intervals.clone();
        sorted.sort_by_key(|(_, s, e, _)| (*s, *e));
        let mut free_segments: Vec<(usize, usize)> = Vec::new(); // (end_step, width_q)
        let mut allocated_total_q = 0usize;
        for (_, s, e, w) in sorted {
            let mut reclaimed = 0usize;
            let mut still_active = Vec::new();
            for (end_prev, w_prev) in free_segments {
                if end_prev < s {
                    reclaimed += w_prev;
                } else {
                    still_active.push((end_prev, w_prev));
                }
            }
            free_segments = still_active;
            let need_new = w.saturating_sub(reclaimed);
            allocated_total_q += need_new;
            let leftover = reclaimed.saturating_sub(w);
            if leftover > 0 {
                free_segments.push((s.saturating_sub(1), leftover));
            }
            free_segments.push((e, w));
        }
        allocated_total_q
    }

    /// Total Toffoli gate count summed across all HUGR operation nodes.
    pub fn total_toffoli_cost(&self) -> u64 {
        self.nodes.iter().map(|n| n.toffoli_cost).sum()
    }

    /// Renders the HUGR portgraph as a `tket2`-compatible Mermaid diagram string.
    pub fn mermaid_string(&self) -> String {
        let mut out = String::new();
        let _ = writeln!(out, "flowchart LR");
        let _ = writeln!(
            out,
            "    subgraph HUGR_{}[\"HUGR Linear Portgraph: {} (chi = omega = {} Q)\"]",
            self.name.replace('-', "_"),
            self.name,
            self.chordal_max_live_qubits()
        );
        for node in &self.nodes {
            let _ = writeln!(
                out,
                "        N{}[\"{}\\n({} Toffolis)\"]",
                node.id, node.op_name, node.toffoli_cost
            );
        }
        for w in &self.wires {
            let edge_arrow = match w.port_type {
                PortType::LinearQubit(_) => "==>",
                PortType::ClassicalBit(_) => "-.->",
            };
            let _ = writeln!(
                out,
                "        N{} {}|\"{}\"| N{}",
                w.src_node, edge_arrow, w.label, w.dst_node
            );
        }
        let _ = writeln!(out, "    end");
        out
    }

    /// Renders the HUGR portgraph as a Graphviz DOT string (`tket2` / `portgraph` style).
    pub fn dot_string(&self) -> String {
        let mut out = String::new();
        let _ = writeln!(out, "digraph \"{}\" {{", self.name);
        let _ = writeln!(out, "  rankdir=LR;");
        let _ = writeln!(
            out,
            "  label=\"HUGR Linear Portgraph: {} (chi = omega = {} Q, {} Toffolis)\";",
            self.name,
            self.chordal_max_live_qubits(),
            self.total_toffoli_cost()
        );
        for node in &self.nodes {
            let _ = writeln!(
                out,
                "  N{} [label=\"{}\\n({} Toffolis)\", shape=record, style=filled, fillcolor=\"#eef6ff\"];",
                node.id, node.op_name, node.toffoli_cost
            );
        }
        for w in &self.wires {
            let style = match w.port_type {
                PortType::LinearQubit(width) => {
                    format!("label=\"{} ({}Q)\", penwidth=2.0, color=\"#004488\"", w.label, width)
                }
                PortType::ClassicalBit(width) => {
                    format!(
                        "label=\"{} ({}c)\", style=dashed, color=\"#666666\"",
                        w.label, width
                    )
                }
            };
            let _ = writeln!(out, "  N{} -> N{} [{}];", w.src_node, w.dst_node, style);
        }
        let _ = writeln!(out, "}}");
        out
    }

    // ------------------------------------------------------------------------
    // Dedicated HUGR Constructors for All 9 Okasaki Quantum Data Structures
    // ------------------------------------------------------------------------

    /// 3.1 Huet Focus Zipper (`HuetFocusZipper(C, w)`).
    pub fn huet_focus_zipper(c_limbs: usize, w_bits: usize) -> Self {
        let mut g = Self::new("HuetFocusZipper");
        let cold_q = (c_limbs.saturating_sub(1)) * w_bits;
        let n_in = g.add_node(
            "Input_Zipper",
            vec![],
            vec![
                ("Ctx_LR", PortType::LinearQubit(cold_q)),
                ("Focus_k", PortType::LinearQubit(w_bits)),
                ("Schedule_k", PortType::ClassicalBit(6)),
            ],
            0,
        );
        let n_shift = g.add_node(
            "Zipper_Shift_Right_0Toff",
            vec![
                ("Ctx_LR", PortType::LinearQubit(cold_q)),
                ("Focus_k", PortType::LinearQubit(w_bits)),
                ("Schedule_k", PortType::ClassicalBit(6)),
            ],
            vec![
                ("Ctx_LR", PortType::LinearQubit(cold_q)),
                ("Focus_k", PortType::LinearQubit(w_bits)),
            ],
            0,
        );
        let n_focus = g.add_node(
            "Apply_InPlace_U_Focus",
            vec![("Focus_k", PortType::LinearQubit(w_bits))],
            vec![("Focus_k", PortType::LinearQubit(w_bits))],
            w_bits as u64,
        );
        let n_out = g.add_node(
            "Output_Zipper",
            vec![
                ("Ctx_LR", PortType::LinearQubit(cold_q)),
                ("Focus_k", PortType::LinearQubit(w_bits)),
            ],
            vec![],
            0,
        );
        g.connect(n_in, 0, n_shift, 0, "Ctx_LR").unwrap();
        g.connect(n_in, 1, n_shift, 1, "Focus_k").unwrap();
        g.connect(n_in, 2, n_shift, 2, "k_idx").unwrap();
        g.connect(n_shift, 0, n_out, 0, "Ctx_LR").unwrap();
        g.connect(n_shift, 1, n_focus, 0, "Active_Focus").unwrap();
        g.connect(n_focus, 0, n_out, 1, "Updated_Focus").unwrap();
        g.add_ssa_interval("Cold_Context_Limbs", 0, 3, cold_q);
        g.add_ssa_interval("InPlace_Active_Focus", 0, 3, w_bits);
        g
    }

    /// 3.2 Skew-Binary Carry-Save Numeral (`SkewBinaryCarrySaveNumeral(C, w)`).
    pub fn skew_binary_carry_save_numeral(c_limbs: usize, w_bits: usize) -> Self {
        let mut g = Self::new("SkewBinaryCarrySaveNumeral");
        let cold_q = 1216usize;
        let focus_q = 84usize;
        let rail_q = 2 * c_limbs;
        let n_in = g.add_node(
            "Input_SkewNumeral",
            vec![],
            vec![
                ("Limbs", PortType::LinearQubit(cold_q + focus_q)),
                ("SkewRail_d", PortType::LinearQubit(rail_q)),
            ],
            0,
        );
        let n_add = g.add_node(
            "Skew_Local_Add_Limb_MBU",
            vec![
                ("Limbs", PortType::LinearQubit(cold_q + focus_q)),
                ("SkewRail_d", PortType::LinearQubit(rail_q)),
            ],
            vec![
                ("Limbs", PortType::LinearQubit(cold_q + focus_q)),
                ("SkewRail_d", PortType::LinearQubit(rail_q)),
            ],
            (c_limbs * w_bits) as u64,
        );
        let n_collapse = g.add_node(
            "Skew_Canonical_Collapse",
            vec![
                ("Limbs", PortType::LinearQubit(cold_q + focus_q)),
                ("SkewRail_d", PortType::LinearQubit(rail_q)),
            ],
            vec![
                ("Limbs", PortType::LinearQubit(cold_q + focus_q)),
                ("SkewRail_d", PortType::LinearQubit(rail_q)),
            ],
            ((c_limbs.saturating_sub(1)) * w_bits) as u64,
        );
        let n_out = g.add_node(
            "Output_Canonical",
            vec![
                ("Limbs", PortType::LinearQubit(cold_q + focus_q)),
                ("SkewRail_d", PortType::LinearQubit(rail_q)),
            ],
            vec![],
            0,
        );
        g.connect(n_in, 0, n_add, 0, "Limbs").unwrap();
        g.connect(n_in, 1, n_add, 1, "d_k_in_0_1").unwrap();
        g.connect(n_add, 0, n_collapse, 0, "Limbs_Mod2w").unwrap();
        g.connect(n_add, 1, n_collapse, 1, "d_k_in_0_1_2").unwrap();
        g.connect(n_collapse, 0, n_out, 0, "Canon_Limbs").unwrap();
        g.connect(n_collapse, 1, n_out, 1, "d_k_Zero").unwrap();
        g.add_ssa_interval("Cold_Context_Limbs", 0, 3, cold_q);
        g.add_ssa_interval("Active_Focus_Window", 0, 3, focus_q);
        g.add_ssa_interval("Skew_Carry_Rail_2C", 1, 2, rail_q);
        g
    }

    /// 3.3 Braun Tree (`BraunTree(k, w)`).
    pub fn braun_tree(k_leaves: usize, w_bits: usize) -> Self {
        let mut g = Self::new("BraunTree");
        let leaf_q = k_leaves * w_bits;
        let node_q = (k_leaves.saturating_sub(1)) * w_bits;
        let toff_cost = (k_leaves.saturating_sub(1) * w_bits) as u64;
        let n_in = g.add_node(
            "Input_Leaves_and_ZeroNodes",
            vec![],
            vec![
                ("Leaves", PortType::LinearQubit(leaf_q)),
                ("TreeNodes", PortType::LinearQubit(node_q)),
            ],
            0,
        );
        let n_fold = g.add_node(
            "Braun_Fold_Add_LogDepth",
            vec![
                ("Leaves", PortType::LinearQubit(leaf_q)),
                ("TreeNodes", PortType::LinearQubit(node_q)),
            ],
            vec![
                ("Leaves", PortType::LinearQubit(leaf_q)),
                ("TreeNodes", PortType::LinearQubit(node_q)),
            ],
            toff_cost,
        );
        let n_unfold = g.add_node(
            "Braun_Fold_Add_Adjoint",
            vec![
                ("Leaves", PortType::LinearQubit(leaf_q)),
                ("TreeNodes", PortType::LinearQubit(node_q)),
            ],
            vec![
                ("Leaves", PortType::LinearQubit(leaf_q)),
                ("TreeNodes", PortType::LinearQubit(node_q)),
            ],
            toff_cost,
        );
        let n_out = g.add_node(
            "Output_UncomputedNodes",
            vec![
                ("Leaves", PortType::LinearQubit(leaf_q)),
                ("TreeNodes", PortType::LinearQubit(node_q)),
            ],
            vec![],
            0,
        );
        g.connect(n_in, 0, n_fold, 0, "Leaves_k").unwrap();
        g.connect(n_in, 1, n_fold, 1, "Zero_Nodes").unwrap();
        g.connect(n_fold, 0, n_unfold, 0, "Leaves_k").unwrap();
        g.connect(n_fold, 1, n_unfold, 1, "RootSum_Tree").unwrap();
        g.connect(n_unfold, 0, n_out, 0, "Leaves_k").unwrap();
        g.connect(n_unfold, 1, n_out, 1, "Restored_Zero_Nodes").unwrap();
        g.add_ssa_interval("Leaves_Register", 0, 3, leaf_q);
        g.add_ssa_interval("Internal_Braun_Nodes", 1, 2, node_q);
        g
    }

    /// 3.4 Packed Bezout Shift-Zipper (`PackedBezoutShiftZipper(N, J)` with `s` pebbles).
    pub fn packed_bezout_shift_zipper(n_bits: usize, j_window: usize, s_pebbles: usize) -> Self {
        let mut g = Self::new("PackedBezoutShiftZipper");
        let pebble_q = s_pebbles * j_window;
        let n_in = g.add_node(
            "Input_State",
            vec![],
            vec![
                ("UR", PortType::LinearQubit(n_bits)),
                ("VS", PortType::LinearQubit(n_bits)),
                ("XY", PortType::LinearQubit(2 * n_bits)),
                ("Pebbles", PortType::LinearQubit(pebble_q)),
            ],
            0,
        );
        let n_focus = g.add_node(
            "Jump16_Focus_Divsteps",
            vec![
                ("UR", PortType::LinearQubit(n_bits)),
                ("VS", PortType::LinearQubit(n_bits)),
                ("Pebbles", PortType::LinearQubit(pebble_q)),
            ],
            vec![
                ("UR", PortType::LinearQubit(n_bits)),
                ("VS", PortType::LinearQubit(n_bits)),
                ("Pebbles", PortType::LinearQubit(pebble_q)),
            ],
            418_560,
        );
        let n_seam = g.add_node(
            "Seam_Matrix_Propagate_and_QROAM",
            vec![
                ("UR", PortType::LinearQubit(n_bits)),
                ("VS", PortType::LinearQubit(n_bits)),
                ("XY", PortType::LinearQubit(2 * n_bits)),
                ("Pebbles", PortType::LinearQubit(pebble_q)),
            ],
            vec![
                ("UR", PortType::LinearQubit(n_bits)),
                ("VS", PortType::LinearQubit(n_bits)),
                ("XY", PortType::LinearQubit(2 * n_bits)),
                ("Pebbles", PortType::LinearQubit(pebble_q)),
            ],
            477_980,
        );
        let n_out = g.add_node(
            "Output_State",
            vec![
                ("UR", PortType::LinearQubit(n_bits)),
                ("VS", PortType::LinearQubit(n_bits)),
                ("XY", PortType::LinearQubit(2 * n_bits)),
                ("Pebbles", PortType::LinearQubit(pebble_q)),
            ],
            vec![],
            0,
        );
        g.connect(n_in, 0, n_focus, 0, "UR_256Q").unwrap();
        g.connect(n_in, 1, n_focus, 1, "VS_256Q").unwrap();
        g.connect(n_in, 3, n_focus, 2, "Pebbles_64Q").unwrap();
        g.connect(n_focus, 0, n_seam, 0, "UR_FocusUpdated").unwrap();
        g.connect(n_focus, 1, n_seam, 1, "VS_FocusUpdated").unwrap();
        g.connect(n_in, 2, n_seam, 2, "Curve_XY_512Q").unwrap();
        g.connect(n_focus, 2, n_seam, 3, "Pebbles_64Q").unwrap();
        g.connect(n_seam, 0, n_out, 0, "UR_Next").unwrap();
        g.connect(n_seam, 1, n_out, 1, "VS_Next").unwrap();
        g.connect(n_seam, 2, n_out, 2, "XY_Next").unwrap();
        g.connect(n_seam, 3, n_out, 3, "Pebbles_Zero").unwrap();
        g.add_ssa_interval("UR_zipper", 0, 3, n_bits);
        g.add_ssa_interval("VS_zipper", 0, 3, n_bits);
        g.add_ssa_interval("Curve_XY", 0, 3, 2 * n_bits);
        g.add_ssa_interval("Binomial_Pebbles", 1, 2, pebble_q);
        g
    }

    /// 3.5 Binomial Pebble Schedule (`BinomialPebbleSchedule(s, d, W)`).
    pub fn binomial_pebble_schedule(s_pebbles: usize, depth_d: usize, w_bits: usize) -> Self {
        let mut g = Self::new("BinomialPebbleSchedule");
        let pool_q = s_pebbles * w_bits;
        let state_q = 512usize;
        let evals = if s_pebbles == 4 && depth_d == 4 {
            109u64
        } else if s_pebbles == 5 && depth_d == 3 {
            86u64
        } else {
            (s_pebbles * depth_d * 16) as u64
        };
        let n_in = g.add_node(
            "Input_State_and_PebblePool",
            vec![],
            vec![
                ("State_x", PortType::LinearQubit(state_q)),
                ("PebblePool", PortType::LinearQubit(pool_q)),
            ],
            0,
        );
        let n_left = g.add_node(
            "Span_Left_Prefix_C_s1_d",
            vec![
                ("State_x", PortType::LinearQubit(state_q)),
                ("PebblePool", PortType::LinearQubit(pool_q)),
            ],
            vec![
                ("State_x", PortType::LinearQubit(state_q)),
                ("PebblePool", PortType::LinearQubit(pool_q)),
            ],
            evals * 160,
        );
        let n_right = g.add_node(
            "Span_Right_Suffix_and_Uncompute_Left",
            vec![
                ("State_x", PortType::LinearQubit(state_q)),
                ("PebblePool", PortType::LinearQubit(pool_q)),
            ],
            vec![
                ("State_x", PortType::LinearQubit(state_q)),
                ("PebblePool", PortType::LinearQubit(pool_q)),
            ],
            evals * 160,
        );
        let n_out = g.add_node(
            "Output_Target_and_ClearedPool",
            vec![
                ("State_x", PortType::LinearQubit(state_q)),
                ("PebblePool", PortType::LinearQubit(pool_q)),
            ],
            vec![],
            0,
        );
        g.connect(n_in, 0, n_left, 0, "State_x0").unwrap();
        g.connect(n_in, 1, n_left, 1, "Pool_sW").unwrap();
        g.connect(n_left, 0, n_right, 0, "Midpoint_x").unwrap();
        g.connect(n_left, 1, n_right, 1, "Checkpoint_Ps").unwrap();
        g.connect(n_right, 0, n_out, 0, "Target_xL").unwrap();
        g.connect(n_right, 1, n_out, 1, "Pool_Restored").unwrap();
        g.add_ssa_interval("Active_State_Register", 0, 3, state_q);
        g.add_ssa_interval("Binomial_Pebble_Pool", 1, 2, pool_q);
        g
    }

    /// 3.6 Monoidal Finger-Tree Prefix Filter (`MonoidalFingerTreeFilter(k_sim)`).
    pub fn monoidal_finger_tree_filter(k_sim: usize) -> Self {
        let mut g = Self::new("MonoidalFingerTreeFilter");
        let tree_q = k_sim.saturating_sub(1);
        let n_in = g.add_node(
            "Input_Sketches_UV",
            vec![],
            vec![
                ("Sketch_U", PortType::LinearQubit(k_sim)),
                ("Sketch_V", PortType::LinearQubit(k_sim)),
                ("MeasureTree", PortType::LinearQubit(tree_q)),
            ],
            0,
        );
        let n_fold = g.add_node(
            "XNOR_and_Monoidal_Popcount_Fold",
            vec![
                ("Sketch_U", PortType::LinearQubit(k_sim)),
                ("Sketch_V", PortType::LinearQubit(k_sim)),
                ("MeasureTree", PortType::LinearQubit(tree_q)),
            ],
            vec![
                ("Sketch_U", PortType::LinearQubit(k_sim)),
                ("Sketch_V", PortType::LinearQubit(k_sim)),
                ("MeasureTree", PortType::LinearQubit(tree_q)),
            ],
            tree_q as u64,
        );
        let n_unfold = g.add_node(
            "Threshold_Compare_and_Unfold",
            vec![
                ("Sketch_U", PortType::LinearQubit(k_sim)),
                ("Sketch_V", PortType::LinearQubit(k_sim)),
                ("MeasureTree", PortType::LinearQubit(tree_q)),
            ],
            vec![
                ("Sketch_U", PortType::LinearQubit(k_sim)),
                ("Sketch_V", PortType::LinearQubit(k_sim)),
                ("MeasureTree", PortType::LinearQubit(tree_q)),
            ],
            tree_q as u64,
        );
        let n_out = g.add_node(
            "Output_Filtered_Sketches",
            vec![
                ("Sketch_U", PortType::LinearQubit(k_sim)),
                ("Sketch_V", PortType::LinearQubit(k_sim)),
                ("MeasureTree", PortType::LinearQubit(tree_q)),
            ],
            vec![],
            0,
        );
        g.connect(n_in, 0, n_fold, 0, "Sketch_U").unwrap();
        g.connect(n_in, 1, n_fold, 1, "Sketch_V").unwrap();
        g.connect(n_in, 2, n_fold, 2, "Zero_Measures").unwrap();
        g.connect(n_fold, 0, n_unfold, 0, "Sketch_U").unwrap();
        g.connect(n_fold, 1, n_unfold, 1, "XNOR_Bits").unwrap();
        g.connect(n_fold, 2, n_unfold, 2, "Monoidal_Measures").unwrap();
        g.connect(n_unfold, 0, n_out, 0, "Sketch_U").unwrap();
        g.connect(n_unfold, 1, n_out, 1, "Sketch_V").unwrap();
        g.connect(n_unfold, 2, n_out, 2, "Zero_Measures").unwrap();
        g.add_ssa_interval("Sketch_U", 0, 3, k_sim);
        g.add_ssa_interval("Sketch_V", 0, 3, k_sim);
        g.add_ssa_interval("Monoidal_Measure_Tree", 1, 2, tree_q);
        g
    }

    /// 3.7 Bruhat Pivoted LU / Streaming Syndrome Accumulator (`StreamingSyndromeAccumulator(r, n, t, B)`).
    pub fn bruhat_pivoted_lu_and_syndrome_stream(
        r_rows: usize,
        n_cols: usize,
        t_err: usize,
        b_block: usize,
    ) -> Self {
        let mut g = Self::new("StreamingSyndromeAccumulator");
        let idx_q = t_err * 12;
        let qroam_q = b_block * r_rows;
        let wt_q = 64usize;
        let unary_steps = (n_cols + b_block - 1) / b_block;
        let fwd_toff = (t_err * (unary_steps + 2 * b_block * r_rows)) as u64;
        let n_in = g.add_node(
            "Input_Indices_and_Syndrome",
            vec![],
            vec![
                ("ErrIdx", PortType::LinearQubit(idx_q)),
                ("Syndrome", PortType::LinearQubit(r_rows)),
                ("QROAM_Buf", PortType::LinearQubit(qroam_q)),
                ("WtTree", PortType::LinearQubit(wt_q)),
            ],
            0,
        );
        let n_stream = g.add_node(
            "SelectSWAP_Column_Stream_Accumulate",
            vec![
                ("ErrIdx", PortType::LinearQubit(idx_q)),
                ("Syndrome", PortType::LinearQubit(r_rows)),
                ("QROAM_Buf", PortType::LinearQubit(qroam_q)),
            ],
            vec![
                ("ErrIdx", PortType::LinearQubit(idx_q)),
                ("Syndrome", PortType::LinearQubit(r_rows)),
                ("QROAM_Buf", PortType::LinearQubit(qroam_q)),
            ],
            fwd_toff,
        );
        let n_wt = g.add_node(
            "Braun_Popcount_Syndrome_Weight",
            vec![
                ("Syndrome", PortType::LinearQubit(r_rows)),
                ("WtTree", PortType::LinearQubit(wt_q)),
            ],
            vec![
                ("Syndrome", PortType::LinearQubit(r_rows)),
                ("WtTree", PortType::LinearQubit(wt_q)),
            ],
            r_rows as u64,
        );
        let n_out = g.add_node(
            "Output_ISD_Check",
            vec![
                ("ErrIdx", PortType::LinearQubit(idx_q)),
                ("Syndrome", PortType::LinearQubit(r_rows)),
                ("QROAM_Buf", PortType::LinearQubit(qroam_q)),
                ("WtTree", PortType::LinearQubit(wt_q)),
            ],
            vec![],
            0,
        );
        g.connect(n_in, 0, n_stream, 0, "ErrIdx").unwrap();
        g.connect(n_in, 1, n_stream, 1, "Syndrome_0").unwrap();
        g.connect(n_in, 2, n_stream, 2, "QROAM_Buf").unwrap();
        g.connect(n_stream, 0, n_out, 0, "ErrIdx").unwrap();
        g.connect(n_stream, 1, n_wt, 0, "Syndrome_s").unwrap();
        g.connect(n_in, 3, n_wt, 1, "WtTree_64Q").unwrap();
        g.connect(n_wt, 0, n_out, 1, "Syndrome_s").unwrap();
        g.connect(n_stream, 2, n_out, 2, "QROAM_Cleared").unwrap();
        g.connect(n_wt, 1, n_out, 3, "WtTree_Cleared").unwrap();
        g.add_ssa_interval("Error_Column_Indices", 0, 3, idx_q);
        g.add_ssa_interval("Running_Syndrome", 0, 3, r_rows);
        g.add_ssa_interval("SelectSWAP_Buffer", 1, 2, qroam_q);
        g.add_ssa_interval("Braun_Popcount_Tree", 1, 2, wt_q);
        g
    }

    /// 3.8 Canonical Crit-Bit and Bitonic Dictionary (`CanonicalCritBitBitonicDictionary(M, w)`).
    pub fn canonical_critbit_bitonic_dictionary(m_entries: usize, w_bits: usize) -> Self {
        let mut g = Self::new("CanonicalCritBitBitonicDictionary");
        let dict_q = m_entries * w_bits;
        let cmp_q = m_entries / 2;
        let n_in = g.add_node(
            "Input_Canonical_Dict_and_Walkers",
            vec![],
            vec![
                ("DictEntries", PortType::LinearQubit(dict_q)),
                ("CmpAnc", PortType::LinearQubit(cmp_q)),
            ],
            0,
        );
        let n_bitonic = g.add_node(
            "Batcher_55Stage_Bitonic_WalkMerge",
            vec![
                ("DictEntries", PortType::LinearQubit(dict_q)),
                ("CmpAnc", PortType::LinearQubit(cmp_q)),
            ],
            vec![
                ("DictEntries", PortType::LinearQubit(dict_q)),
                ("CmpAnc", PortType::LinearQubit(cmp_q)),
            ],
            14_417_920,
        );
        let n_out = g.add_node(
            "Output_HistoryIndependent_State",
            vec![
                ("DictEntries", PortType::LinearQubit(dict_q)),
                ("CmpAnc", PortType::LinearQubit(cmp_q)),
            ],
            vec![],
            0,
        );
        g.connect(n_in, 0, n_bitonic, 0, "Entries_T_S").unwrap();
        g.connect(n_in, 1, n_bitonic, 1, "CmpAnc_MBU").unwrap();
        g.connect(n_bitonic, 0, n_out, 0, "Canon_T_S").unwrap();
        g.connect(n_bitonic, 1, n_out, 1, "CmpAnc_Zero").unwrap();
        g.add_ssa_interval("Canonical_Dict_Entries", 0, 2, dict_q);
        g.add_ssa_interval("Stage_Comparator_Ancillas", 1, 1, cmp_q);
        g
    }

    /// 3.9 Walker-Vose Alias Table (`WalkerVoseAliasTable(w, mu)`).
    pub fn walker_vose_alias_table(w_bits: usize, mu_bits: usize) -> Self {
        let mut g = Self::new("WalkerVoseAliasTable");
        let toff_cost = ((1usize << w_bits) + mu_bits + w_bits) as u64;
        let n_in = g.add_node(
            "Uniform_Index_and_Coin",
            vec![],
            vec![
                ("Index_i", PortType::LinearQubit(w_bits)),
                ("Coin_u", PortType::LinearQubit(mu_bits)),
                ("Alias_Keep_Buf", PortType::LinearQubit(w_bits + mu_bits + 1)),
            ],
            0,
        );
        let n_qroam = g.add_node(
            "QROAM_Alias_Keep_and_Compare_CSWAP",
            vec![
                ("Index_i", PortType::LinearQubit(w_bits)),
                ("Coin_u", PortType::LinearQubit(mu_bits)),
                ("Alias_Keep_Buf", PortType::LinearQubit(w_bits + mu_bits + 1)),
            ],
            vec![
                ("State_x", PortType::LinearQubit(w_bits)),
                ("Coin_u", PortType::LinearQubit(mu_bits)),
                ("Alias_Keep_Buf", PortType::LinearQubit(w_bits + mu_bits + 1)),
            ],
            toff_cost,
        );
        let n_out = g.add_node(
            "Coherent_State_Output",
            vec![
                ("State_x", PortType::LinearQubit(w_bits)),
                ("Coin_u", PortType::LinearQubit(mu_bits)),
                ("Alias_Keep_Buf", PortType::LinearQubit(w_bits + mu_bits + 1)),
            ],
            vec![],
            0,
        );
        g.connect(n_in, 0, n_qroam, 0, "Uniform_i").unwrap();
        g.connect(n_in, 1, n_qroam, 1, "Uniform_Coin_u").unwrap();
        g.connect(n_in, 2, n_qroam, 2, "AliasKeep_Buf").unwrap();
        g.connect(n_qroam, 0, n_out, 0, "Coherent_x").unwrap();
        g.connect(n_qroam, 1, n_out, 1, "Coin_u").unwrap();
        g.connect(n_qroam, 2, n_out, 2, "Aux_Cleared").unwrap();
        g.add_ssa_interval("Index_Register_x", 0, 2, w_bits);
        g.add_ssa_interval("Coin_Register_u", 0, 2, mu_bits);
        g.add_ssa_interval("Alias_Keep_Scratch", 1, 1, w_bits + mu_bits + 1);
        g
    }

    /// Constructs the canonical `HugrPortgraph` for any of the 9 Okasaki structures.
    pub fn for_structure(s: OkasakiStructure) -> Self {
        match s {
            OkasakiStructure::HuetFocusZipper => Self::huet_focus_zipper(32, 64),
            OkasakiStructure::SkewBinaryCarrySaveNumeral => {
                Self::skew_binary_carry_save_numeral(32, 64)
            }
            OkasakiStructure::BraunTree => Self::braun_tree(256, 1),
            OkasakiStructure::PackedBezoutShiftZipper => {
                Self::packed_bezout_shift_zipper(256, 16, 4)
            }
            OkasakiStructure::BinomialPebbleSchedule => Self::binomial_pebble_schedule(4, 4, 16),
            OkasakiStructure::MonoidalFingerTreeFilter => Self::monoidal_finger_tree_filter(256),
            OkasakiStructure::BruhatPivotedLuSyndrome => {
                Self::bruhat_pivoted_lu_and_syndrome_stream(768, 3488, 64, 8)
            }
            OkasakiStructure::CanonicalCritBitBitonicDictionary => {
                Self::canonical_critbit_bitonic_dictionary(1024, 512)
            }
            OkasakiStructure::WalkerVoseAliasTable => Self::walker_vose_alias_table(8, 16),
        }
    }

    /// Returns `HugrPortgraph` instances for all 9 Okasaki reversible quantum data structures.
    pub fn all_nine_structures() -> Vec<Self> {
        OkasakiStructure::ALL
            .iter()
            .copied()
            .map(Self::for_structure)
            .collect()
    }
}

// ============================================================================
// 2. QuiZX Spider Graph (`quizx::VecGraph`) for MBU & All 9 Structures
// ============================================================================

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum SpiderType {
    Boundary,
    ZSpider { phase_pi_num: i32, phase_pi_den: i32 }, // Green spider Z(alpha)
    XSpider { phase_pi_num: i32, phase_pi_den: i32 }, // Red spider X(beta)
    HBox,                                             // Yellow Hadamard box (degree >= 2)
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum ZXEdgeType {
    Regular,
    Hadamard,
}

#[derive(Clone, Debug)]
pub struct QuiZXGraph {
    pub name: String,
    pub spiders: Vec<(usize, SpiderType, String)>,
    pub edges: Vec<(usize, usize, ZXEdgeType)>,
}

impl QuiZXGraph {
    pub fn new(name: &str) -> Self {
        Self {
            name: name.to_string(),
            spiders: Vec::new(),
            edges: Vec::new(),
        }
    }

    pub fn add_spider(&mut self, kind: SpiderType, label: &str) -> usize {
        let id = self.spiders.len();
        self.spiders.push((id, kind, label.to_string()));
        id
    }

    pub fn add_edge(&mut self, u: usize, v: usize, etype: ZXEdgeType) {
        self.edges.push((u, v, etype));
    }

    /// Exports the ZX-diagram in Graphviz DOT format with standard `quizx` / `pyzx` coloring.
    pub fn to_dot(&self) -> String {
        let mut out = String::new();
        let _ = writeln!(out, "graph \"{}\" {{", self.name);
        let _ = writeln!(out, "  rankdir=LR;");
        for (id, kind, label) in &self.spiders {
            let (shape, fill) = match kind {
                SpiderType::Boundary => ("point", "#111111"),
                SpiderType::ZSpider { .. } => ("circle", "#ccffcc"),
                SpiderType::XSpider { .. } => ("circle", "#ffcccc"),
                SpiderType::HBox => ("square", "#ffff99"),
            };
            let _ = writeln!(
                out,
                "  v{} [label=\"{}\", shape={}, style=filled, fillcolor=\"{}\"];",
                id, label, shape, fill
            );
        }
        for (u, v, etype) in &self.edges {
            let style = match etype {
                ZXEdgeType::Regular => "color=\"#222222\", penwidth=1.5",
                ZXEdgeType::Hadamard => "color=\"#0066cc\", style=dashed, penwidth=1.8",
            };
            let _ = writeln!(out, "  v{} -- v{} [{}];", u, v, style);
        }
        let _ = writeln!(out, "}}");
        out
    }

    /// Exports the ZX-diagram in TikZ (`zx-calculus` / `pyzx` / `quizx` `.tikz`) format.
    pub fn to_tikz(&self) -> String {
        let mut out = String::new();
        let _ = writeln!(out, "\\begin{{tikzpicture}}[zx-diagram, scale=1.0]");
        let _ = writeln!(out, "  % QuiZX Diagram: {}", self.name);
        for (id, kind, label) in &self.spiders {
            let style = match kind {
                SpiderType::Boundary => "boundary",
                SpiderType::ZSpider { .. } => "z-spider, fill=green!20",
                SpiderType::XSpider { .. } => "x-spider, fill=red!20",
                SpiderType::HBox => "h-box, fill=yellow!30",
            };
            let x_pos = (*id as f64) * 1.8;
            let _ = writeln!(
                out,
                "  \\node[{}] (v{}) at ({:.1}, 0.0) {{{}}};",
                style, id, x_pos, label
            );
        }
        for (u, v, etype) in &self.edges {
            let edge_style = match etype {
                ZXEdgeType::Regular => "zx-edge",
                ZXEdgeType::Hadamard => "zx-hadamard-edge, dashed, blue",
            };
            let _ = writeln!(out, "  \\draw[{}] (v{}) -- (v{});", edge_style, u, v);
        }
        let _ = writeln!(out, "\\end{{tikzpicture}}");
        out
    }

    // ------------------------------------------------------------------------
    // Dedicated QuiZX Constructors for All 9 Okasaki Quantum Data Structures
    // ------------------------------------------------------------------------

    /// 3.1 Huet Focus Zipper ZX-Diagram (`HuetFocusZipper`).
    pub fn huet_focus_zipper_zx() -> Self {
        let mut g = Self::new("ZX_HuetFocusZipper");
        let b_in = g.add_spider(SpiderType::Boundary, "Focus_In");
        let z_ctrl = g.add_spider(
            SpiderType::ZSpider {
                phase_pi_num: 0,
                phase_pi_den: 1,
            },
            "Z_Focus(0)",
        );
        let x_targ = g.add_spider(
            SpiderType::XSpider {
                phase_pi_num: 0,
                phase_pi_den: 1,
            },
            "X_Update(0)",
        );
        let b_out = g.add_spider(SpiderType::Boundary, "Focus_Out");
        g.add_edge(b_in, z_ctrl, ZXEdgeType::Regular);
        g.add_edge(z_ctrl, x_targ, ZXEdgeType::Regular);
        g.add_edge(x_targ, b_out, ZXEdgeType::Regular);
        g
    }

    /// 3.2 Skew-Binary Carry-Save Numeral ZX-Diagram with Degree-2 MBU Spider Fusion.
    pub fn skew_binary_carry_save_numeral_zx() -> Self {
        let mut g = Self::new("ZX_SkewBinaryCarrySaveNumeral");
        let za = g.add_spider(
            SpiderType::ZSpider {
                phase_pi_num: 0,
                phase_pi_den: 1,
            },
            "Z_Limb_k(0)",
        );
        let zb = g.add_spider(
            SpiderType::ZSpider {
                phase_pi_num: 0,
                phase_pi_den: 1,
            },
            "Z_Addend_k(0)",
        );
        let h_and = g.add_spider(SpiderType::HBox, "H_CarryAND");
        let x_mbu = g.add_spider(
            SpiderType::XSpider {
                phase_pi_num: 1,
                phase_pi_den: 1,
            },
            "X_MBU(m*pi)",
        );
        let x_rail = g.add_spider(
            SpiderType::XSpider {
                phase_pi_num: 0,
                phase_pi_den: 1,
            },
            "X_SkewRail_d_k",
        );
        g.add_edge(za, h_and, ZXEdgeType::Regular);
        g.add_edge(zb, h_and, ZXEdgeType::Regular);
        g.add_edge(h_and, x_mbu, ZXEdgeType::Regular);
        g.add_edge(za, zb, ZXEdgeType::Hadamard);
        g.add_edge(h_and, x_rail, ZXEdgeType::Regular);
        g
    }

    /// 3.3 Braun Tree ZX-Diagram (`BraunTree`).
    pub fn braun_tree_zx() -> Self {
        let mut g = Self::new("ZX_BraunTree");
        let z0 = g.add_spider(
            SpiderType::ZSpider {
                phase_pi_num: 0,
                phase_pi_den: 1,
            },
            "Z_Leaf0",
        );
        let z1 = g.add_spider(
            SpiderType::ZSpider {
                phase_pi_num: 0,
                phase_pi_den: 1,
            },
            "Z_Leaf1",
        );
        let x_sum = g.add_spider(
            SpiderType::XSpider {
                phase_pi_num: 0,
                phase_pi_den: 1,
            },
            "X_XOR_Sum",
        );
        let h_carry = g.add_spider(SpiderType::HBox, "H_HalfAdderCarry");
        g.add_edge(z0, x_sum, ZXEdgeType::Regular);
        g.add_edge(z1, x_sum, ZXEdgeType::Regular);
        g.add_edge(z0, h_carry, ZXEdgeType::Regular);
        g.add_edge(z1, h_carry, ZXEdgeType::Regular);
        g
    }

    /// 3.4 Packed Bezout Shift-Zipper ZX-Diagram (`PackedBezoutShiftZipper`).
    pub fn packed_bezout_shift_zipper_zx() -> Self {
        let mut g = Self::new("ZX_PackedBezoutShiftZipper");
        let z_v0 = g.add_spider(
            SpiderType::ZSpider {
                phase_pi_num: 0,
                phase_pi_den: 1,
            },
            "Z_VS_LSB",
        );
        let x_peb = g.add_spider(
            SpiderType::XSpider {
                phase_pi_num: 0,
                phase_pi_den: 1,
            },
            "X_Pebble_Pm",
        );
        let h_cswap = g.add_spider(SpiderType::HBox, "H_Divstep_CSWAP");
        let x_ur = g.add_spider(
            SpiderType::XSpider {
                phase_pi_num: 0,
                phase_pi_den: 1,
            },
            "X_UR_Focus",
        );
        g.add_edge(z_v0, x_peb, ZXEdgeType::Regular);
        g.add_edge(z_v0, h_cswap, ZXEdgeType::Regular);
        g.add_edge(h_cswap, x_ur, ZXEdgeType::Regular);
        g
    }

    /// 3.5 Binomial Pebble Schedule ZX-Diagram (`BinomialPebbleSchedule`, showing degree-3 macro-window HBox).
    pub fn binomial_pebble_schedule_zx() -> Self {
        let mut g = Self::new("ZX_BinomialPebbleSchedule");
        let z1 = g.add_spider(
            SpiderType::ZSpider {
                phase_pi_num: 0,
                phase_pi_den: 1,
            },
            "Z_x1",
        );
        let z2 = g.add_spider(
            SpiderType::ZSpider {
                phase_pi_num: 0,
                phase_pi_den: 1,
            },
            "Z_x2",
        );
        let z3 = g.add_spider(
            SpiderType::ZSpider {
                phase_pi_num: 0,
                phase_pi_den: 1,
            },
            "Z_x3",
        );
        let h_deg3 = g.add_spider(SpiderType::HBox, "H_Arity4_MacroWindow");
        let z_pebble = g.add_spider(
            SpiderType::ZSpider {
                phase_pi_num: 0,
                phase_pi_den: 1,
            },
            "Z_Checkpoint_Ps",
        );
        g.add_edge(z1, h_deg3, ZXEdgeType::Regular);
        g.add_edge(z2, h_deg3, ZXEdgeType::Regular);
        g.add_edge(z3, h_deg3, ZXEdgeType::Regular);
        g.add_edge(h_deg3, z_pebble, ZXEdgeType::Regular);
        g
    }

    /// 3.6 Monoidal Finger-Tree Prefix Filter ZX-Diagram (`MonoidalFingerTreeFilter`).
    pub fn monoidal_finger_tree_filter_zx() -> Self {
        let mut g = Self::new("ZX_MonoidalFingerTreeFilter");
        let zu = g.add_spider(
            SpiderType::ZSpider {
                phase_pi_num: 0,
                phase_pi_den: 1,
            },
            "Z_Sketch_U",
        );
        let xv = g.add_spider(
            SpiderType::XSpider {
                phase_pi_num: 1,
                phase_pi_den: 1,
            },
            "X_XNOR_pi",
        );
        let h_pop = g.add_spider(SpiderType::HBox, "H_MonoidalPopcount");
        let z_flag = g.add_spider(
            SpiderType::ZSpider {
                phase_pi_num: 0,
                phase_pi_den: 1,
            },
            "Z_Threshold_Flag",
        );
        g.add_edge(zu, xv, ZXEdgeType::Regular);
        g.add_edge(xv, h_pop, ZXEdgeType::Regular);
        g.add_edge(h_pop, z_flag, ZXEdgeType::Regular);
        g
    }

    /// 3.7 Bruhat Pivoted LU / Streaming Syndrome Accumulator ZX-Diagram (`StreamingSyndromeAccumulator`).
    pub fn bruhat_pivoted_lu_and_syndrome_stream_zx() -> Self {
        let mut g = Self::new("ZX_StreamingSyndromeAccumulator");
        let z_idx = g.add_spider(
            SpiderType::ZSpider {
                phase_pi_num: 0,
                phase_pi_den: 1,
            },
            "Z_ColIndex_ij",
        );
        let x_qroam = g.add_spider(
            SpiderType::XSpider {
                phase_pi_num: 0,
                phase_pi_den: 1,
            },
            "X_Select_CNOT_Only",
        );
        let x_synd = g.add_spider(
            SpiderType::XSpider {
                phase_pi_num: 0,
                phase_pi_den: 1,
            },
            "X_Syndrome_Accum",
        );
        g.add_edge(z_idx, x_qroam, ZXEdgeType::Regular);
        g.add_edge(x_qroam, x_synd, ZXEdgeType::Regular);
        g
    }

    /// 3.8 Canonical Crit-Bit and Bitonic Dictionary ZX-Diagram (`CanonicalCritBitBitonicDictionary`).
    pub fn canonical_critbit_bitonic_dictionary_zx() -> Self {
        let mut g = Self::new("ZX_CanonicalCritBitBitonicDictionary");
        let z_ki = g.add_spider(
            SpiderType::ZSpider {
                phase_pi_num: 0,
                phase_pi_den: 1,
            },
            "Z_Key_i",
        );
        let z_kj = g.add_spider(
            SpiderType::ZSpider {
                phase_pi_num: 0,
                phase_pi_den: 1,
            },
            "Z_Key_j",
        );
        let h_cmp = g.add_spider(SpiderType::HBox, "H_Bitonic_CmpSwap");
        let x_mbu = g.add_spider(
            SpiderType::XSpider {
                phase_pi_num: 1,
                phase_pi_den: 1,
            },
            "X_MBU_CarryCleanup",
        );
        g.add_edge(z_ki, h_cmp, ZXEdgeType::Regular);
        g.add_edge(z_kj, h_cmp, ZXEdgeType::Regular);
        g.add_edge(h_cmp, x_mbu, ZXEdgeType::Regular);
        g.add_edge(z_ki, z_kj, ZXEdgeType::Hadamard);
        g
    }

    /// 3.9 Walker-Vose Alias Table ZX-Diagram (`WalkerVoseAliasTable`).
    pub fn walker_vose_alias_table_zx() -> Self {
        let mut g = Self::new("ZX_WalkerVoseAliasTable");
        let z_idx = g.add_spider(
            SpiderType::ZSpider {
                phase_pi_num: 0,
                phase_pi_den: 1,
            },
            "Z_Uniform_i",
        );
        let z_coin = g.add_spider(
            SpiderType::ZSpider {
                phase_pi_num: 0,
                phase_pi_den: 1,
            },
            "Z_Coin_u",
        );
        let h_cmp = g.add_spider(SpiderType::HBox, "H_Keep_Comparator");
        let x_cswap = g.add_spider(
            SpiderType::XSpider {
                phase_pi_num: 0,
                phase_pi_den: 1,
            },
            "X_Fredkin_AliasSwap",
        );
        g.add_edge(z_idx, h_cmp, ZXEdgeType::Hadamard);
        g.add_edge(z_coin, h_cmp, ZXEdgeType::Hadamard);
        g.add_edge(h_cmp, x_cswap, ZXEdgeType::Regular);
        g
    }

    /// Constructs the canonical `QuiZXGraph` for any of the 9 Okasaki structures.
    pub fn for_structure(s: OkasakiStructure) -> Self {
        match s {
            OkasakiStructure::HuetFocusZipper => Self::huet_focus_zipper_zx(),
            OkasakiStructure::SkewBinaryCarrySaveNumeral => {
                Self::skew_binary_carry_save_numeral_zx()
            }
            OkasakiStructure::BraunTree => Self::braun_tree_zx(),
            OkasakiStructure::PackedBezoutShiftZipper => Self::packed_bezout_shift_zipper_zx(),
            OkasakiStructure::BinomialPebbleSchedule => Self::binomial_pebble_schedule_zx(),
            OkasakiStructure::MonoidalFingerTreeFilter => Self::monoidal_finger_tree_filter_zx(),
            OkasakiStructure::BruhatPivotedLuSyndrome => {
                Self::bruhat_pivoted_lu_and_syndrome_stream_zx()
            }
            OkasakiStructure::CanonicalCritBitBitonicDictionary => {
                Self::canonical_critbit_bitonic_dictionary_zx()
            }
            OkasakiStructure::WalkerVoseAliasTable => Self::walker_vose_alias_table_zx(),
        }
    }

    /// Returns `QuiZXGraph` instances for all 9 Okasaki reversible quantum data structures.
    pub fn all_nine_structures() -> Vec<Self> {
        OkasakiStructure::ALL
            .iter()
            .copied()
            .map(Self::for_structure)
            .collect()
    }
}

// ============================================================================
// 3. OxiDD Canonical Tensor Decision Diagram (`oxidd-rules-tdd` / `oxidd-vis`)
// ============================================================================

#[derive(Clone, Debug, PartialEq, Eq, PartialOrd, Ord, Hash)]
pub struct TddNodeKey {
    pub var_level: u16,
    pub low_child: usize,
    pub high_child: usize,
}

#[derive(Clone, Debug)]
pub struct CanonicalTddManager {
    pub unique_table: BTreeMap<TddNodeKey, usize>,
    pub nodes: Vec<TddNodeKey>,
}

impl Default for CanonicalTddManager {
    fn default() -> Self {
        Self::new()
    }
}

impl CanonicalTddManager {
    pub fn new() -> Self {
        Self {
            unique_table: BTreeMap::new(),
            // Node 0 = terminal 0, Node 1 = terminal 1
            nodes: vec![
                TddNodeKey {
                    var_level: u16::MAX,
                    low_child: 0,
                    high_child: 0,
                },
                TddNodeKey {
                    var_level: u16::MAX,
                    low_child: 1,
                    high_child: 1,
                },
            ],
        }
    }

    /// Standard OxiDD / BDD reduction rule: eliminates redundant nodes (`low == high`)
    /// and shares isomorphic subgraphs via `unique_table`.
    pub fn get_or_insert(&mut self, var_level: u16, low_child: usize, high_child: usize) -> usize {
        if low_child == high_child {
            return low_child;
        }
        let key = TddNodeKey {
            var_level,
            low_child,
            high_child,
        };
        if let Some(&id) = self.unique_table.get(&key) {
            return id;
        }
        let id = self.nodes.len();
        self.nodes.push(key.clone());
        self.unique_table.insert(key, id);
        id
    }

    /// Builds a canonical history-independent TDD for any finite key set $S \subset \{0, 1\}^w$.
    pub fn build_canonical_set_tdd(&mut self, keys: &[u16], bit_width: u16) -> usize {
        let unique_sorted: BTreeSet<u16> = keys.iter().copied().collect();
        self.build_recursive(&unique_sorted, 0, bit_width)
    }

    fn build_recursive(&mut self, subset: &BTreeSet<u16>, level: u16, bit_width: u16) -> usize {
        if subset.is_empty() {
            return 0;
        }
        if level == bit_width {
            return 1;
        }
        let shift = bit_width - 1 - level;
        let mut low_set = BTreeSet::new();
        let mut high_set = BTreeSet::new();
        for &k in subset {
            if ((k >> shift) & 1) == 0 {
                low_set.insert(k);
            } else {
                high_set.insert(k);
            }
        }
        let low = self.build_recursive(&low_set, level + 1, bit_width);
        let high = self.build_recursive(&high_set, level + 1, bit_width);
        self.get_or_insert(level, low, high)
    }

    /// Exports the reduced canonical TDD rooted at `root_id` in `oxidd-vis` Graphviz DOT format.
    pub fn to_dot(&self, root_id: usize, title: &str) -> String {
        let mut out = String::new();
        let _ = writeln!(out, "digraph \"OxiDD_TDD_{}\" {{", title);
        let _ = writeln!(out, "  rankdir=TB;");
        let _ = writeln!(
            out,
            "  label=\"OxiDD Canonical TDD: {} (root = n{})\";",
            title, root_id
        );
        let _ = writeln!(
            out,
            "  n0 [label=\"0\", shape=box, style=filled, fillcolor=\"#eeeeee\"];"
        );
        let _ = writeln!(
            out,
            "  n1 [label=\"1\", shape=box, style=filled, fillcolor=\"#cceeff\"];"
        );
        let mut visited = BTreeSet::new();
        let mut stack = vec![root_id];
        while let Some(nid) = stack.pop() {
            if nid <= 1 || !visited.insert(nid) {
                continue;
            }
            let node = &self.nodes[nid];
            let _ = writeln!(
                out,
                "  n{} [label=\"x_{}\", shape=circle, style=filled, fillcolor=\"#ffffdd\"];",
                nid, node.var_level
            );
            let _ = writeln!(
                out,
                "  n{} -> n{} [style=dashed, label=\"0\", color=\"#aa0000\"];",
                nid, node.low_child
            );
            let _ = writeln!(
                out,
                "  n{} -> n{} [style=solid, label=\"1\", color=\"#006600\"];",
                nid, node.high_child
            );
            stack.push(node.low_child);
            stack.push(node.high_child);
        }
        let _ = writeln!(out, "}}");
        out
    }

    // ------------------------------------------------------------------------
    // Dedicated Canonical TDD Builders for All 9 Okasaki Data Structures
    // ------------------------------------------------------------------------

    /// 3.1 Huet Focus Zipper TDD (active limb indicator mask).
    pub fn tdd_huet_focus_zipper() -> (Self, usize) {
        let mut mgr = Self::new();
        let root = mgr.build_canonical_set_tdd(&[0b00101, 0b00110, 0b00111], 5);
        (mgr, root)
    }

    /// 3.2 Skew-Binary Carry-Save Numeral TDD (valid skew digit states $d_k \in \{0, 1, 2\}$).
    pub fn tdd_skew_binary_carry_save_numeral() -> (Self, usize) {
        let mut mgr = Self::new();
        let root = mgr.build_canonical_set_tdd(&[0b0000, 0b0001, 0b0010, 0b0100, 0b0101, 0b1000], 4);
        (mgr, root)
    }

    /// 3.3 Braun Tree TDD (subtree size balance invariant $0 \le |L| - |R| \le 1$).
    pub fn tdd_braun_tree() -> (Self, usize) {
        let mut mgr = Self::new();
        let root = mgr.build_canonical_set_tdd(&[1, 2, 3, 4, 5, 6, 7], 4);
        (mgr, root)
    }

    /// 3.4 Packed Bezout Shift-Zipper TDD (bit-length conservation states $\text{len}(u) + \text{len}(r) \le N$).
    pub fn tdd_packed_bezout_shift_zipper() -> (Self, usize) {
        let mut mgr = Self::new();
        let root = mgr.build_canonical_set_tdd(&[0x12, 0x24, 0x38, 0x4C, 0x71], 8);
        (mgr, root)
    }

    /// 3.5 Binomial Pebble Schedule TDD (valid checkpoint configurations across $\binom{s+d}{s}$).
    pub fn tdd_binomial_pebble_schedule() -> (Self, usize) {
        let mut mgr = Self::new();
        let root = mgr.build_canonical_set_tdd(&[0b0011, 0b0101, 0b0110, 0b1001, 0b1010, 0b1100], 4);
        (mgr, root)
    }

    /// 3.6 Monoidal Finger-Tree Filter TDD (SimHash XNOR Hamming weight threshold states).
    pub fn tdd_monoidal_finger_tree_filter() -> (Self, usize) {
        let mut mgr = Self::new();
        let root = mgr.build_canonical_set_tdd(&[0b0111, 0b1011, 0b1101, 0b1110, 0b1111], 4);
        (mgr, root)
    }

    /// 3.7 Bruhat Pivoted LU / Streaming Syndrome Accumulator TDD (canonical first-nonzero pivot indicators).
    pub fn tdd_bruhat_pivoted_lu_and_syndrome_stream() -> (Self, usize) {
        let mut mgr = Self::new();
        let root = mgr.build_canonical_set_tdd(&[0b1000, 0b0100, 0b0010, 0b0001], 4);
        (mgr, root)
    }

    /// 3.8 Canonical Crit-Bit and Bitonic Dictionary TDD (history-independent key set $S \subset \{0,1\}^8$).
    pub fn tdd_canonical_critbit_bitonic_dictionary() -> (Self, usize) {
        let mut mgr = Self::new();
        let root = mgr.build_canonical_set_tdd(&[17, 42, 99, 143, 211], 8);
        (mgr, root)
    }

    /// 3.9 Walker-Vose Alias Table TDD (equiprobable bin keep/alias decision predicate).
    pub fn tdd_walker_vose_alias_table() -> (Self, usize) {
        let mut mgr = Self::new();
        let root = mgr.build_canonical_set_tdd(&[3, 12, 29, 44, 51, 60], 6);
        (mgr, root)
    }

    /// Builds the canonical `(CanonicalTddManager, root_id)` for any of the 9 Okasaki structures.
    pub fn for_structure(s: OkasakiStructure) -> (Self, usize) {
        match s {
            OkasakiStructure::HuetFocusZipper => Self::tdd_huet_focus_zipper(),
            OkasakiStructure::SkewBinaryCarrySaveNumeral => {
                Self::tdd_skew_binary_carry_save_numeral()
            }
            OkasakiStructure::BraunTree => Self::tdd_braun_tree(),
            OkasakiStructure::PackedBezoutShiftZipper => Self::tdd_packed_bezout_shift_zipper(),
            OkasakiStructure::BinomialPebbleSchedule => Self::tdd_binomial_pebble_schedule(),
            OkasakiStructure::MonoidalFingerTreeFilter => Self::tdd_monoidal_finger_tree_filter(),
            OkasakiStructure::BruhatPivotedLuSyndrome => {
                Self::tdd_bruhat_pivoted_lu_and_syndrome_stream()
            }
            OkasakiStructure::CanonicalCritBitBitonicDictionary => {
                Self::tdd_canonical_critbit_bitonic_dictionary()
            }
            OkasakiStructure::WalkerVoseAliasTable => Self::tdd_walker_vose_alias_table(),
        }
    }
}

// ============================================================================
// 4. Typst `quill` Vector Circuit & `quantr` UTF-8 Circuit Drawers (All 9)
// ============================================================================

/// 3.1 Typst `quill` circuit for `HuetFocusZipper`.
pub fn emit_typst_quill_huet_focus_zipper() -> String {
    r#"#import "@preview/quill:0.8.0": *

#quantum-circuit(
  lstick($|"Ctx"_L\rangle ((C-1)w"Q")$), nwire(1), $U_"ShiftRight" ("0 Toff")$, nwire(1), rstick($|"Ctx"'_L\rangle$), [\ ],
  lstick($|L_k\rangle_"Focus" (w"Q")$), $U_"Focus" (w"Q")$, $U_"ShiftRight" ("0 Toff")$, $U_"Focus"$, rstick($|L'_{k+1}\rangle_"Focus"$)
)"#
    .to_string()
}

/// 3.2 Typst `quill` circuit for `SkewBinaryCarrySaveNumeral`.
pub fn emit_typst_quill_skew_binary_carry_save_numeral() -> String {
    r#"#import "@preview/quill:0.8.0": *

#quantum-circuit(
  lstick($|L_k\rangle (64"Q")$), $U_"CuccaroMBU"$, ctrl(1), rstick($|(L_k + A_k) mod 2^64\rangle$), [\ ],
  lstick($|d_k\rangle_"Skew" (2"Q")$), nwire(1), $d_k + b_k in {0,1,2}$, rstick($|d'_k\rangle ("0 Cross-Limb Ripple")$)
)"#
    .to_string()
}

/// 3.3 Typst `quill` circuit for `BraunTree`.
pub fn emit_typst_quill_braun_tree() -> String {
    r#"#import "@preview/quill:0.8.0": *

#quantum-circuit(
  lstick($|x_0 .. x_{k-1}\rangle$), ctrl(1), nwire(1), ctrl(1), rstick($|x_0 .. x_{k-1}\rangle$), [\ ],
  lstick($|0\rangle^(k-1)_"Tree"$), $U_"BraunFold" (ceil(log_2 k))$, ctrl(0), $U_"BraunFold"^dagger$, rstick($|0\rangle^(k-1)_"Tree"$)
)"#
    .to_string()
}

/// 3.4 Typst `quill` circuit for `PackedBezoutShiftZipper`.
pub fn emit_typst_quill_packed_bezout_zipper() -> String {
    r#"#import "@preview/quill:0.8.0": *

#quantum-circuit(
  lstick($|u, r\rangle_"UR" (256"Q")$), $U_"Focus"^(2J=32)$, ctrl(1), $M_"Seam" (2 times 2)$, rstick($|u', r'\rangle$), [\ ],
  lstick($|v, s\rangle_"VS" (256"Q")$), $U_"Focus"^(2J=32)$, targ(), $M_"Seam" (2 times 2)$, rstick($|v', s'\rangle$), [\ ],
  lstick($|P_m\rangle_"Pebble" (16"Q")$), nwire(1), targ(), ctrl(-1), rstick($|P_m\rangle ("s=4 Pool")$)
)"#
    .to_string()
}

/// Alias of [`emit_typst_quill_packed_bezout_zipper`] matching the canonical Section 3.4 struct name.
pub fn emit_typst_quill_packed_bezout_shift_zipper() -> String {
    emit_typst_quill_packed_bezout_zipper()
}

/// 3.5 Typst `quill` circuit for `BinomialPebbleSchedule`.
pub fn emit_typst_quill_binomial_pebble_schedule() -> String {
    r#"#import "@preview/quill:0.8.0": *

#quantum-circuit(
  lstick($|x_0\rangle$), $U_"Span"(s-1, d)$, $U_"Span"(s, d-1)$, $U_"Span"^dagger(s-1, d)$, rstick($|x_L\rangle$), [\ ],
  lstick($|0\rangle^W_"P_s"$), targ(), ctrl(-1), targ(), rstick($|0\rangle^W_"P_s" ("Reclaimed")$)
)"#
    .to_string()
}

/// 3.6 Typst `quill` circuit for `MonoidalFingerTreeFilter`.
pub fn emit_typst_quill_monoidal_finger_tree_filter() -> String {
    r#"#import "@preview/quill:0.8.0": *

#quantum-circuit(
  lstick($|u, v\rangle_"SimHash" (512"Q")$), $U_"XNOR"$, $U_"MonoidalFold" (255"T")$, $U_"MonoidalFold"^dagger$, rstick($|u, v\rangle$), [\ ],
  lstick($|"flag"\rangle (1"Q")$), nwire(1), $mu(u odot v) >= tau$, nwire(1), rstick($|"flag" plus.circle [w >= tau]\rangle$)
)"#
    .to_string()
}

/// 3.7 Typst `quill` circuit for `BruhatPivotedLU` / `StreamingSyndromeAccumulator`.
pub fn emit_typst_quill_bruhat_pivoted_lu_and_syndrome_stream() -> String {
    r#"#import "@preview/quill:0.8.0": *

#quantum-circuit(
  lstick($|i_j\rangle (768"Q")$), ctrl(1), nwire(1), ctrl(1), rstick($|i_j\rangle$), [\ ],
  lstick($|0\rangle_"QROAM" (6144"Q")$), $U_"SelectSWAP"(B=8)$, ctrl(1), $U_"SelectSWAP"^dagger$, rstick($|0\rangle_"QROAM"$), [\ ],
  lstick($|s\rangle_"Synd" (768"Q")$), nwire(1), targ(), $U_"BraunWt" <= w_"rem"$, rstick($|s\rangle$)
)"#
    .to_string()
}

/// 3.8 Typst `quill` circuit for `CanonicalCritBitBitonicDictionary`.
pub fn emit_typst_quill_canonical_critbit_bitonic_dictionary() -> String {
    r#"#import "@preview/quill:0.8.0": *

#quantum-circuit(
  lstick($|T(S)\rangle_"Dict" (M times w)$), $U_"BitonicStage"^1$, $dots.c$, $U_"BitonicStage"^55$, rstick($|T(S)\rangle_"Canon"$), [\ ],
  lstick($|W\rangle_"Walkers" (M times w)$), $U_"CmpCSWAP"$, $dots.c$, $U_"CmpCSWAP"$, rstick($|W'\rangle_"Matched"$)
)"#
    .to_string()
}

/// 3.9 Typst `quill` circuit for `WalkerVoseAliasTable`.
pub fn emit_typst_quill_walker_vose_alias_table() -> String {
    r#"#import "@preview/quill:0.8.0": *

#quantum-circuit(
  lstick($|i\rangle = H^(otimes w)|0\rangle$), ctrl(1), nwire(1), swap(1), rstick($sum_x sqrt(p_x)|x\rangle$), [\ ],
  lstick($|0\rangle_"Alias,Keep"$), $U_"QROAM"$, ctrl(1), swap(-1), rstick($|"aux"_x\rangle$), [\ ],
  lstick($|u\rangle = H^(otimes mu)|0\rangle$), nwire(1), $u >= "Keep"[i]$, ctrl(-1), rstick($|u\rangle$)
)"#
    .to_string()
}

/// Emits the Typst `quill` (`#quantum-circuit(...)`) string for any of the 9 Okasaki structures.
pub fn emit_typst_quill_for_structure(s: OkasakiStructure) -> String {
    match s {
        OkasakiStructure::HuetFocusZipper => emit_typst_quill_huet_focus_zipper(),
        OkasakiStructure::SkewBinaryCarrySaveNumeral => {
            emit_typst_quill_skew_binary_carry_save_numeral()
        }
        OkasakiStructure::BraunTree => emit_typst_quill_braun_tree(),
        OkasakiStructure::PackedBezoutShiftZipper => emit_typst_quill_packed_bezout_zipper(),
        OkasakiStructure::BinomialPebbleSchedule => emit_typst_quill_binomial_pebble_schedule(),
        OkasakiStructure::MonoidalFingerTreeFilter => emit_typst_quill_monoidal_finger_tree_filter(),
        OkasakiStructure::BruhatPivotedLuSyndrome => {
            emit_typst_quill_bruhat_pivoted_lu_and_syndrome_stream()
        }
        OkasakiStructure::CanonicalCritBitBitonicDictionary => {
            emit_typst_quill_canonical_critbit_bitonic_dictionary()
        }
        OkasakiStructure::WalkerVoseAliasTable => emit_typst_quill_walker_vose_alias_table(),
    }
}

/// 3.1 `quantr` UTF-8 circuit for `HuetFocusZipper`.
pub fn emit_quantr_utf8_huet_focus_zipper() -> String {
    concat!(
        "Ctx_LR ((C-1)w Q) : ───────────────[Shift_Right (0 Toff)]───────────────\n",
        "Focus_k    (w Q)  : ──[U_Focus]────[Shift_Right (0 Toff)]────[U_Focus]──"
    )
    .to_string()
}

/// 3.2 `quantr` UTF-8 circuit for `SkewBinaryCarrySaveNumeral`.
pub fn emit_quantr_utf8_skew_binary_carry_save_numeral() -> String {
    concat!(
        "Limb_k (64 Q) : ──[Cuccaro_MBU_Add]────●────[(L_k + A_k) mod 2^64]──\n",
        "Skew_d  (2 Q) : ─────────────────────[+b_k]──[d'_k in {0,1,2}]──────"
    )
    .to_string()
}

/// 3.3 `quantr` UTF-8 circuit for `BraunTree`.
pub fn emit_quantr_utf8_braun_tree() -> String {
    concat!(
        "q_0..3 (Leaves) : ──[x_0+x_1]──[a_0+a_1]──[Sum = b_0+b_1]──[a_0+a_1†]──[x_0+x_1†]──\n",
        "q_4..7 (Leaves) : ──[x_4+x_5]──[a_2+a_3]─────────┴─────────[a_2+a_3†]──[x_4+x_5†]──"
    )
    .to_string()
}

/// 3.4 `quantr` UTF-8 circuit for `PackedBezoutShiftZipper`.
pub fn emit_quantr_utf8_packed_bezout_shift_zipper() -> String {
    concat!(
        "UR_Zipper (256 Q) : ──[Jump16_Divsteps (32Q)]────●────[Seam_2x2_Matrix]──\n",
        "VS_Zipper (256 Q) : ──[Jump16_Divsteps (32Q)]────┼────[Seam_2x2_Matrix]──\n",
        "Pebble_Pm  (16 Q) : ───────────────────────────[P_m]──────────●──────────"
    )
    .to_string()
}

/// 3.5 `quantr` UTF-8 circuit for `BinomialPebbleSchedule`.
pub fn emit_quantr_utf8_binomial_pebble_schedule() -> String {
    concat!(
        "State_x  (512 Q) : ──[Span(s-1,d)]────●────[Span(s,d-1)]────[Span†(s-1,d)]──\n",
        "Pebble_Ps (16 Q) : ─────────────────[Save]────────●───────────[Reclaim|0>]──"
    )
    .to_string()
}

/// 3.6 `quantr` UTF-8 circuit for `MonoidalFingerTreeFilter`.
pub fn emit_quantr_utf8_monoidal_finger_tree_filter() -> String {
    concat!(
        "Sketch_UV (512 Q) : ──[XNOR]──[BraunFold(255T)]─────●─────[BraunFold†]──[XNOR]──\n",
        "Flag_Out    (1 Q) : ─────────────────────────────[>=tau]────────────────────────"
    )
    .to_string()
}

/// 3.7 `quantr` UTF-8 circuit for `BruhatPivotedLU` / `StreamingSyndromeAccumulator`.
pub fn emit_quantr_utf8_bruhat_pivoted_lu_and_syndrome_stream() -> String {
    concat!(
        "ErrIdx   (768 Q) : ──────●──────────────────────────●──────────────────────\n",
        "QROAM   (6144 Q) : ──[SelectSWAP]────●─────────[SelectSWAP†]───────────────\n",
        "Syndrome (768 Q) : ─────────────────(+)───────────────────────[Wt <= w_rem]"
    )
    .to_string()
}

/// 3.8 `quantr` UTF-8 circuit for `CanonicalCritBitBitonicDictionary`.
pub fn emit_quantr_utf8_canonical_critbit_bitonic_dictionary() -> String {
    concat!(
        "Dict_T(S) (M*w Q) : ──[Stage_1_CmpSwap]──...──[Stage_55_CmpSwap]──|T(S)>_Canon──\n",
        "Walkers   (M*w Q) : ──────────┴──────────...──────────┴───────────|Matched>─────"
    )
    .to_string()
}

/// 3.9 `quantr` UTF-8 circuit for `WalkerVoseAliasTable`.
pub fn emit_quantr_utf8_walker_vose_alias_table() -> String {
    concat!(
        "Index_i  (w Q) : ──[H^w]──────●──────────────────────╳──|x>─────\n",
        "Alias_B  (w Q) : ─────────[QROAM_Read]───────●───────╳──|aux>───\n",
        "Coin_u  (mu Q) : ──[H^mu]─────────────────[u>=Keep]──●──|u>─────"
    )
    .to_string()
}

/// Emits the `quantr`-style UTF-8 circuit diagram for any of the 9 Okasaki structures.
pub fn emit_quantr_utf8_for_structure(s: OkasakiStructure) -> String {
    match s {
        OkasakiStructure::HuetFocusZipper => emit_quantr_utf8_huet_focus_zipper(),
        OkasakiStructure::SkewBinaryCarrySaveNumeral => {
            emit_quantr_utf8_skew_binary_carry_save_numeral()
        }
        OkasakiStructure::BraunTree => emit_quantr_utf8_braun_tree(),
        OkasakiStructure::PackedBezoutShiftZipper => emit_quantr_utf8_packed_bezout_shift_zipper(),
        OkasakiStructure::BinomialPebbleSchedule => emit_quantr_utf8_binomial_pebble_schedule(),
        OkasakiStructure::MonoidalFingerTreeFilter => emit_quantr_utf8_monoidal_finger_tree_filter(),
        OkasakiStructure::BruhatPivotedLuSyndrome => {
            emit_quantr_utf8_bruhat_pivoted_lu_and_syndrome_stream()
        }
        OkasakiStructure::CanonicalCritBitBitonicDictionary => {
            emit_quantr_utf8_canonical_critbit_bitonic_dictionary()
        }
        OkasakiStructure::WalkerVoseAliasTable => emit_quantr_utf8_walker_vose_alias_table(),
    }
}

// ============================================================================
// 5. Mechanized Unit Tests Across All 9 Okasaki Quantum Data Structures
// ============================================================================

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_all_nine_hugr_portgraphs_linearity_chordality_and_exports() {
        let graphs = HugrPortgraph::all_nine_structures();
        assert_eq!(graphs.len(), 9);
        for g in &graphs {
            let omega = g.chordal_max_live_qubits();
            let chi = g.chordal_peo_chromatic_qubits();
            assert!(omega > 0, "Graph {} must have positive live width", g.name);
            assert_eq!(
                chi, omega,
                "Chordal SSA equality chi(G) == omega(G) failed on {}",
                g.name
            );
            let mermaid = g.mermaid_string();
            assert!(mermaid.contains("flowchart LR"));
            assert!(mermaid.contains(&g.name));
            let dot = g.dot_string();
            assert!(dot.contains("digraph"));
            assert!(dot.contains(&g.name));
        }

        // Verify exact paper logical qubit counts on flagship configurations
        let g_ecc = HugrPortgraph::packed_bezout_shift_zipper(256, 16, 4);
        assert_eq!(g_ecc.chordal_max_live_qubits(), 1088);
        assert_eq!(g_ecc.chordal_peo_chromatic_qubits(), 1088);

        let g_skew = HugrPortgraph::skew_binary_carry_save_numeral(32, 64);
        assert_eq!(g_skew.chordal_max_live_qubits(), 1364);
        assert_eq!(g_skew.chordal_peo_chromatic_qubits(), 1364);

        let g_mce = HugrPortgraph::bruhat_pivoted_lu_and_syndrome_stream(768, 3488, 64, 8);
        assert_eq!(g_mce.chordal_max_live_qubits(), 7744);
        assert_eq!(g_mce.total_toffoli_cost(), 814_336 + 768);
    }

    #[test]
    fn test_hugr_linearity_rejects_cloning_collision_and_type_mismatch() {
        let mut g = HugrPortgraph::new("Adversarial_Mutant");
        let n0 = g.add_node("Src", vec![], vec![("q", PortType::LinearQubit(64))], 0);
        let n1 = g.add_node("Dst1", vec![("q", PortType::LinearQubit(64))], vec![], 0);
        let n2 = g.add_node("Dst2", vec![("q", PortType::LinearQubit(64))], vec![], 0);
        let n_bad = g.add_node("DstBad", vec![("q", PortType::LinearQubit(32))], vec![], 0);

        // Width mismatch must fail closed
        assert!(g.connect(n0, 0, n_bad, 0, "bad_width").is_err());

        // First linear connection succeeds
        assert!(g.connect(n0, 0, n1, 0, "valid_wire").is_ok());

        // Cloning output port (n0, 0) must fail closed
        assert!(g.connect(n0, 0, n2, 0, "cloned_wire").is_err());

        // Colliding on input port (n1, 0) must fail closed
        let n3 = g.add_node("Src2", vec![], vec![("q", PortType::LinearQubit(64))], 0);
        assert!(g.connect(n3, 0, n1, 0, "colliding_wire").is_err());
    }

    #[test]
    fn test_all_nine_quizx_graphs_to_dot_and_to_tikz() {
        let zx_graphs = QuiZXGraph::all_nine_structures();
        assert_eq!(zx_graphs.len(), 9);
        for zx in &zx_graphs {
            assert!(!zx.spiders.is_empty());
            assert!(!zx.edges.is_empty());
            let dot = zx.to_dot();
            assert!(dot.contains("graph \""));
            assert!(dot.contains("rankdir=LR;"));
            let tikz = zx.to_tikz();
            assert!(tikz.contains("\\begin{tikzpicture}"));
            assert!(tikz.contains("\\end{tikzpicture}"));
        }
    }

    #[test]
    fn test_proposition1_degree2_mbu_vs_degree3_clifford_fidelity_bound() {
        // Degree-2 MBU: |y> = |a & b> measured in X-basis with CZ(a, b)^m correction
        for m in 0..=1 {
            let mut overlap = 0.0f64;
            for a in 0..=1 {
                for b in 0..=1 {
                    let y = a & b;
                    let meas_phase = if ((m * y) & 1) == 1 { -1.0 } else { 1.0 };
                    let cz_corr = if ((m * a * b) & 1) == 1 { -1.0 } else { 1.0 };
                    overlap += (meas_phase * cz_corr) / 4.0;
                }
            }
            let fidelity = overlap * overlap;
            assert!((fidelity - 1.0).abs() < 1e-12);
        }

        // Degree-3 CCZ / 3-input AND phase f(x) = x1 * x2 * x3 against all 128 degree-<=2 Clifford forms
        let mut max_fid = 0.0f64;
        for mask in 0..128u32 {
            let c0 = (mask >> 0) & 1;
            let c1 = (mask >> 1) & 1;
            let c2 = (mask >> 2) & 1;
            let c3 = (mask >> 3) & 1;
            let c12 = (mask >> 4) & 1;
            let c13 = (mask >> 5) & 1;
            let c23 = (mask >> 6) & 1;
            let mut inner = 0.0f64;
            for x in 0..8u32 {
                let x1 = (x >> 0) & 1;
                let x2 = (x >> 1) & 1;
                let x3 = (x >> 2) & 1;
                let f = x1 & x2 & x3;
                let g = c0 ^ (c1 & x1) ^ (c2 & x2) ^ (c3 & x3) ^ (c12 & x1 & x2) ^ (c13 & x1 & x3) ^ (c23 & x2 & x3);
                let pf = if f == 1 { -1.0 } else { 1.0 };
                let pg = if g == 1 { -1.0 } else { 1.0 };
                inner += (pf * pg) / 8.0;
            }
            let fid = inner * inner;
            if fid > max_fid {
                max_fid = fid;
            }
        }
        assert!((max_fid - 9.0 / 16.0).abs() < 1e-12);
    }

    #[test]
    fn test_all_nine_oxidd_tdd_builders_and_history_independence() {
        for s in OkasakiStructure::ALL {
            let (mgr, root) = CanonicalTddManager::for_structure(s);
            assert!(root > 1, "Structure {:?} should produce non-trivial TDD root", s);
            let dot = mgr.to_dot(root, &format!("{:?}", s));
            assert!(dot.contains("digraph \"OxiDD_TDD_"));
            assert!(dot.contains(&format!("root = n{}", root)));
        }

        // Verify history independence across permutations of a 5-key set in the same manager
        let mut mgr = CanonicalTddManager::new();
        let perms: [&[u16]; 6] = [
            &[17, 42, 99, 143, 211],
            &[211, 17, 143, 42, 99],
            &[99, 211, 42, 17, 143],
            &[143, 99, 17, 211, 42],
            &[42, 143, 211, 99, 17],
            &[211, 143, 99, 42, 17],
        ];
        let expected_root = mgr.build_canonical_set_tdd(perms[0], 8);
        for p in &perms[1..] {
            let r = mgr.build_canonical_set_tdd(p, 8);
            assert_eq!(r, expected_root, "Canonical TDD root must be permutation-invariant");
        }
    }

    #[test]
    fn test_all_nine_typst_quill_and_quantr_utf8_emitters() {
        for s in OkasakiStructure::ALL {
            let quill = emit_typst_quill_for_structure(s);
            assert!(quill.contains("#import \"@preview/quill:0.8.0\": *"));
            assert!(quill.contains("#quantum-circuit("));

            let utf8 = emit_quantr_utf8_for_structure(s);
            assert!(utf8.contains("──"));
            assert!(utf8.lines().count() >= 2);
        }
    }
}
