(******************************************************************************)
(* circuit.ml                                                                 *)
(* ========================================================================== *)
(* Core Reversible & Hardware-Native Quantum Gate AST (`prim_gate`)           *)
(* supporting Simplifications S1–S20 and Today-Available 2025–2026 Hardware.  *)
(******************************************************************************)

type prim_gate =
  | Prim_X           of int
  | Prim_H           of int
  | Prim_Z           of int
  | Prim_SX          of int
  | Prim_RZ          of { wire : int; phi : float }
  | Prim_VirtualRZ   of { wire : int; phi : float }
  | Prim_CNOT        of { ctrl : int; tgt : int }
  | Prim_CZ          of { ctrl : int; tgt : int }
  | Prim_RZZ         of { wire_a : int; wire_b : int; phi : float }
  | Prim_NativeISWAP of { wire_a : int; wire_b : int }
  | Prim_CCX         of { ctrl1 : int; ctrl2 : int; tgt : int }
  | Prim_AndCompute  of { ctrl1 : int; ctrl2 : int; tgt : int }
  | Prim_RCCX        of { ctrl1 : int; ctrl2 : int; tgt : int }
  | Prim_RCCXDag     of { ctrl1 : int; ctrl2 : int; tgt : int }
  | Prim_NativeCCZ   of { ctrl1 : int; ctrl2 : int; tgt : int }
  | Prim_CSWAP       of { ctrl : int; swap1 : int; swap2 : int }
  | Prim_HMR_CZ      of { pebble : int; ctrl1 : int; ctrl2 : int }
  | Prim_MCMR        of { wire : int; zone_id : int }
  | Prim_CatEnt      of { qpu0_w : int; qpu1_w : int }
  | Prim_CatDis      of { qpu0_w : int; qpu1_w : int }

let invert_prim_gate = function
  | (Prim_X _ | Prim_H _ | Prim_Z _ | Prim_SX _
    | Prim_CNOT _ | Prim_CZ _ | Prim_NativeISWAP _
    | Prim_CCX _ | Prim_NativeCCZ _ | Prim_CSWAP _ | Prim_MCMR _) as g -> g
  | Prim_RZ { wire; phi }        -> Prim_RZ { wire; phi = -. phi }
  | Prim_VirtualRZ { wire; phi } -> Prim_VirtualRZ { wire; phi = -. phi }
  | Prim_RZZ { wire_a; wire_b; phi } -> Prim_RZZ { wire_a; wire_b; phi = -. phi }
  | Prim_AndCompute { ctrl1; ctrl2; tgt } -> Prim_HMR_CZ { pebble = tgt; ctrl1; ctrl2 }
  | Prim_HMR_CZ { pebble; ctrl1; ctrl2 }  -> Prim_AndCompute { ctrl1; ctrl2; tgt = pebble }
  | Prim_RCCX { ctrl1; ctrl2; tgt }       -> Prim_RCCXDag { ctrl1; ctrl2; tgt }
  | Prim_RCCXDag { ctrl1; ctrl2; tgt }    -> Prim_RCCX { ctrl1; ctrl2; tgt }
  | Prim_CatEnt { qpu0_w; qpu1_w }        -> Prim_CatDis { qpu0_w; qpu1_w }
  | Prim_CatDis { qpu0_w; qpu1_w }        -> Prim_CatEnt { qpu0_w; qpu1_w }

let invert_prim_list (gs : prim_gate list) : prim_gate list =
  List.rev_map invert_prim_gate gs

let count_toffolis (gs : prim_gate list) : int =
  List.fold_left
    (fun acc g ->
      match g with
      | Prim_CCX _ | Prim_AndCompute _ -> acc + 1
      | _ -> acc)
    0 gs

let count_cswaps (gs : prim_gate list) : int =
  List.fold_left (fun acc g -> match g with Prim_CSWAP _ -> acc + 1 | _ -> acc) 0 gs

let count_cz_gates (gs : prim_gate list) : int =
  List.fold_left
    (fun acc g ->
      match g with
      | Prim_CZ _ | Prim_CNOT _ -> acc + 1
      | Prim_RCCX _ | Prim_RCCXDag _ -> acc + 3
      | Prim_CCX _ -> acc + 6
      | _ -> acc)
    0 gs

let count_mid_circuit_meas (gs : prim_gate list) : int =
  List.fold_left
    (fun acc g ->
      match g with
      | Prim_HMR_CZ _ | Prim_MCMR _ -> acc + 1
      | _ -> acc)
    0 gs

let count_virtual_rz_gates (gs : prim_gate list) : int =
  List.fold_left (fun acc g -> match g with Prim_VirtualRZ _ -> acc + 1 | _ -> acc) 0 gs

let count_rzz_gates (gs : prim_gate list) : int =
  List.fold_left (fun acc g -> match g with Prim_RZZ _ -> acc + 1 | _ -> acc) 0 gs

let count_native_ccz (gs : prim_gate list) : int =
  List.fold_left (fun acc g -> match g with Prim_NativeCCZ _ -> acc + 1 | _ -> acc) 0 gs

let count_native_iswap (gs : prim_gate list) : int =
  List.fold_left (fun acc g -> match g with Prim_NativeISWAP _ -> acc + 1 | _ -> acc) 0 gs
