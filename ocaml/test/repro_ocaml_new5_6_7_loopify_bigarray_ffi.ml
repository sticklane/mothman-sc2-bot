(******************************************************************************)
(* repro_ocaml_new5_6_7_loopify_bigarray_ffi.ml                               *)
(* ========================================================================== *)
(* Standalone OCaml 4.14.1 / Flambda2 Middle-End & C-Runtime Reproducer Suite *)
(* for Wave-21 Track 5 (`OCAML-NEW-5`, `OCAML-NEW-6`, `OCAML-NEW-7`).         *)
(*                                                                            *)
(* Covers:                                                                    *)
(*   1. OCAML-NEW-5: Flambda2 `Loopify` (`middle_end/flambda2/simplify/       *)
(*      loopify.ml`) on mutually-recursive tail calls with unboxed float      *)
(*      accumulators (`float -> float`) where one entry point is called       *)
(*      polymorphically (boxed `Double_tag = 253`) and the loopified join     *)
(*      continuation skips re-unboxing on the backedge/entry.                 *)
(*   2. OCAML-NEW-6: `Bigarray.Array1.sub` / `reshape` (`runtime/bigarray.c`) *)
(*      C-data pointer caching across an inline `Gc.compact()` / custom-block *)
(*      finalizer that relocates or detaches the backing buffer without       *)
(*      refreshing the proxy child `data` pointer.                            *)
(*   3. OCAML-NEW-7: C FFI `caml_callback` (non-`_exn`) vs `caml_callback_exn`*)
(*      (`runtime/callback.c`) exception unwinding across nested C stack      *)
(*      frames leaving `caml_local_roots` linked-list head pointing to a      *)
(*      popped C stack frame.                                                 *)
(******************************************************************************)

(* ========================================================================== *)
(* Bug 1 (OCAML-NEW-5):                                                       *)
(* Flambda2 `Loopify` on Mutually-Recursive Tail Calls with Unboxed Float     *)
(* Accumulators (`Naked_float` vs Boxed `Double_tag 253` Polymorphic Entry)   *)
(* ========================================================================== *)
module Ocaml_New_5_Flambda2_Loopify_Unboxed_Float_Backedge = struct
  (* In Flambda2 (`middle_end/flambda2/simplify/loopify.ml` and
     `unbox_continuation_params.ml`), self- and mutually-recursive tail-recursive
     functions `f` and `g` of type `int -> float -> float` are transformed into a
     single loop continuation `k_loop (n : Tagged_immediate) (acc : Naked_float)`.
     When `f` is entered directly from a monomorphic site, `acc` is unboxed into
     an XMM register (`Naked_float`).
     However, when `g` is also passed to a higher-order polymorphic caller
     `'a -> 'b -> 'b` (which passes `acc` as a boxed `Double_tag = 253` heap
     pointer in an integer register `%rax`), a buggy `Loopify` join-point fusion
     that shares the backedge continuation between the polymorphic wrapper and
     the unboxed mutual recursion without emitting `Unbox_naked_float` treats the
     raw 64-bit heap pointer bits of the boxed `Double_tag (253)` block as an
     IEEE-754 `Naked_float` in `addsd`/`mulsd`! *)

  type float_repr =
    | Naked_ieee754 of int64            (* Unboxed IEEE-754 bits in XMM register *)
    | Boxed_double_tag_253 of {
        heap_addr : int64;              (* Even 64-bit heap pointer, LSB = 0 *)
        ieee_bits : int64;              (* Underlying IEEE-754 payload in field 0 *)
      }

  let float_of_repr_unboxed_buggy (r : float_repr) : (float, string) result =
    match r with
    | Naked_ieee754 bits -> Ok (Int64.float_of_bits bits)
    | Boxed_double_tag_253 { heap_addr; _ } ->
        (* BUG: Loopified continuation `k_loop` expects `Naked_float` in XMM0,
           but receives the raw `heap_addr` pointer bits from the polymorphic
           entry / backedge without unboxing `Double_val(v)`! *)
        Error
          (Printf.sprintf
             "FLAMBDA2_LOOPIFY_UNBOX_MISMATCH:boxed_ptr_0x%Lx_fed_to_naked_float_xmm"
             heap_addr)

  let unbox_at_entry_repaired (r : float_repr) : int64 =
    match r with
    | Naked_ieee754 bits -> bits
    | Boxed_double_tag_253 { ieee_bits; _ } -> ieee_bits

  (* Mutually-recursive tail loop over `steps` iterations with delta `step_delta`:
     Buggy lowering skips `Unbox_naked_float` when entering via the polymorphic
     entry point (`Boxed_double_tag_253`). *)
  let eval_loopify_mutual_float_buggy
      ~(steps : int)
      ~(init_arg : float_repr)
      ~(step_delta : float) : (int64, string) result =
    let rec loop_even n (acc_repr : float_repr) =
      if n <= 0 then
        match acc_repr with
        | Naked_ieee754 bits -> Ok bits
        | Boxed_double_tag_253 { heap_addr; _ } ->
            Error
              (Printf.sprintf
                 "FLAMBDA2_LOOPIFY_BACKEDGE_CORRUPTION:ptr_0x%Lx"
                 heap_addr)
      else
        match float_of_repr_unboxed_buggy acc_repr with
        | Error e -> Error e
        | Ok v ->
            let next_bits = Int64.bits_of_float (v +. step_delta) in
            loop_odd (n - 1) (Naked_ieee754 next_bits)
    and loop_odd n (acc_repr : float_repr) =
      if n <= 0 then
        match acc_repr with
        | Naked_ieee754 bits -> Ok bits
        | Boxed_double_tag_253 { heap_addr; _ } ->
            Error
              (Printf.sprintf
                 "FLAMBDA2_LOOPIFY_BACKEDGE_CORRUPTION:ptr_0x%Lx"
                 heap_addr)
      else
        match float_of_repr_unboxed_buggy acc_repr with
        | Error e -> Error e
        | Ok v ->
            let next_bits = Int64.bits_of_float ((v *. 1.5) +. step_delta) in
            loop_even (n - 1) (Naked_ieee754 next_bits)
    in
    loop_even steps init_arg

  (* Repaired Flambda2 `Loopify` lowering: splits the polymorphic boxed wrapper
     stub from the unboxed `k_loop (acc : Naked_float)` continuation, explicitly
     inserting `Unbox_naked_float` (`Double_val`) at the polymorphic entry and
     maintaining `Naked_ieee754` invariants across all mutual backedges. *)
  let eval_loopify_mutual_float_repaired
      ~(steps : int)
      ~(init_arg : float_repr)
      ~(step_delta : float) : (int64, string) result =
    let unboxed_init_bits = unbox_at_entry_repaired init_arg in
    let rec k_loop_even n (acc_bits : int64) : int64 =
      if n <= 0 then acc_bits
      else
        let v = Int64.float_of_bits acc_bits in
        let next_bits = Int64.bits_of_float (v +. step_delta) in
        k_loop_odd (n - 1) next_bits
    and k_loop_odd n (acc_bits : int64) : int64 =
      if n <= 0 then acc_bits
      else
        let v = Int64.float_of_bits acc_bits in
        let next_bits = Int64.bits_of_float ((v *. 1.5) +. step_delta) in
        k_loop_even (n - 1) next_bits
    in
    Ok (k_loop_even steps unboxed_init_bits)
end

(* ========================================================================== *)
(* Bug 2 (OCAML-NEW-6):                                                       *)
(* `Bigarray.Array1.sub` / `reshape` Proxy Lifetime & Cached `b->data`        *)
(* Pointer Staleness Across `Gc.compact()` / Custom-Block Backing Relocation  *)
(* ========================================================================== *)
module Ocaml_New_6_Bigarray_Sub_Proxy_Lifetime_Gc_Compact = struct
  (* In OCaml's Bigarray runtime (`runtime/bigarray.c`):
     - A `caml_ba_array` header holds `void *data` and `struct caml_ba_proxy *proxy`.
     - When `Bigarray.Array1.sub parent ofs len` creates a sub-array view, both
       `parent` and `sub_view` share a `caml_ba_proxy` struct, and `sub_view->data`
       is initialized to `(char *)parent->data + byte_offset`.
     - If a custom finalizer, managed buffer resize, or `Gc.compact()` callback
       reallocates or relocates the backing store (`proxy->data` moves from
       `old_base_addr` to `new_base_addr`), or if a C caller caches `Caml_ba_data_val(sub)`
       across an inline `Gc.compact()` without refreshing all proxy peers via
       `caml_ba_update_proxy`, `sub_view->data` still points into the freed/relocated
       `old_base_addr + byte_offset`! *)

  type ba_proxy = {
    mutable proxy_base_addr : int64;
    mutable backing_words   : int64 array;
    mutable generation      : int;
  }

  type ba_view = {
    proxy              : ba_proxy;
    elem_offset        : int;
    elem_length        : int;
    mutable cached_ptr : int64; (* Simulates `b->data` pointer in `caml_ba_array` *)
    mutable synced_gen : int;
  }

  let create_parent_ba ~(base_addr : int64) (words : int64 array) : ba_view =
    let proxy = {
      proxy_base_addr = base_addr;
      backing_words = Array.copy words;
      generation = 0;
    } in
    {
      proxy;
      elem_offset = 0;
      elem_length = Array.length words;
      cached_ptr = base_addr;
      synced_gen = 0;
    }

  let sub_ba (parent : ba_view) ~(ofs : int) ~(len : int) : ba_view =
    let byte_ofs = Int64.of_int (ofs * 8) in
    {
      proxy = parent.proxy;
      elem_offset = parent.elem_offset + ofs;
      elem_length = len;
      cached_ptr = Int64.add parent.cached_ptr byte_ofs;
      synced_gen = parent.synced_gen;
    }

  (* Buggy relocation across `Gc.compact()` / backing realloc:
     Updates `parent.proxy.proxy_base_addr` and `parent.cached_ptr`, but fails
     to walk the `caml_ba_proxy` peer list to refresh `sub_view.cached_ptr`! *)
  let compact_and_read_sub_buggy
      (parent : ba_view)
      (sub_view : ba_view)
      ~(new_base_addr : int64)
      ~(idx : int) : (int64, string) result =
    parent.proxy.proxy_base_addr <- new_base_addr;
    parent.proxy.generation <- parent.proxy.generation + 1;
    parent.cached_ptr <- new_base_addr;
    parent.synced_gen <- parent.proxy.generation;
    (* BUG: `sub_view.cached_ptr` was NOT refreshed when `proxy_base_addr` moved! *)
    let expected_sub_ptr =
      Int64.add new_base_addr (Int64.of_int (sub_view.elem_offset * 8))
    in
    if sub_view.cached_ptr <> expected_sub_ptr then
      Error
        (Printf.sprintf
           "UAF_STALE_BIGARRAY_SUB_PTR:cached=0x%Lx_expected=0x%Lx"
           sub_view.cached_ptr
           expected_sub_ptr)
    else
      Ok parent.proxy.backing_words.(sub_view.elem_offset + idx)

  (* Repaired `caml_ba_update_proxy` + `Gc.compact()` root re-derivation:
     Propagates `new_base_addr + elem_offset * 8` to every `ba_view` sharing
     `proxy` before any subsequent element read/write. *)
  let compact_and_read_sub_repaired
      (parent : ba_view)
      (peers : ba_view list)
      (sub_view : ba_view)
      ~(new_base_addr : int64)
      ~(idx : int) : (int64, string) result =
    parent.proxy.proxy_base_addr <- new_base_addr;
    parent.proxy.generation <- parent.proxy.generation + 1;
    List.iter
      (fun view ->
        let byte_ofs = Int64.of_int (view.elem_offset * 8) in
        view.cached_ptr <- Int64.add new_base_addr byte_ofs;
        view.synced_gen <- parent.proxy.generation)
      (parent :: peers);
    let expected_sub_ptr =
      Int64.add new_base_addr (Int64.of_int (sub_view.elem_offset * 8))
    in
    if sub_view.cached_ptr <> expected_sub_ptr || sub_view.synced_gen <> parent.proxy.generation then
      Error "Impossible_unsynced_proxy_view"
    else
      Ok parent.proxy.backing_words.(sub_view.elem_offset + idx)
end

(* ========================================================================== *)
(* Bug 3 (OCAML-NEW-7):                                                       *)
(* C FFI `caml_callback` (non-`_exn`) vs `caml_callback_exn` Unwinding Across *)
(* Nested C Stack Frames Leaving Dangling `caml_local_roots` Head             *)
(* ========================================================================== *)
module Ocaml_New_7_Ffi_Callback_Exn_Local_Roots_Unwind = struct
  (* In OCaml's C FFI (`runtime/caml/memory.h` & `runtime/callback.c`):
     - `CAMLparam1(x)` pushes a stack-allocated `struct caml__roots_block`
       onto the thread-local linked list `caml_local_roots`:
         struct caml__roots_block caml__frame;
         caml__frame.next = caml_local_roots;
         caml_local_roots = &caml__frame;
     - `CAMLreturn(res)` pops the frame:
         caml_local_roots = caml__frame.next;
     - When a C function uses `CAMLparam1(x)` and then calls back into OCaml
       using `caml_callback(closure, arg)` (instead of `caml_callback_exn`),
       if `closure` raises an OCaml exception, `caml_callback` performs a
       direct `siglongjmp` to the outer OCaml exception handler!
     - If the outer handler only restores the `caml_local_roots` cursor saved
       at the outer boundary (or if an intermediate C callback frame bypassed
       `caml_local_roots` restoration across a custom `longjmp` / unguarded C
       frame), `caml_local_roots` remains pointing to `caml__frame` inside the
       popped C stack frame! On the next `Gc.minor()`, the GC traverses the
       dangling `caml__frame` on the popped C stack! *)

  type roots_frame = {
    frame_id    : int;
    mutable on_live_stack : bool;
    root_values : int64 array;
  }

  type runtime_roots_state = {
    mutable caml_local_roots : roots_frame list;
  }

  (* Buggy C FFI wrapper calling `caml_callback` (non-`_exn`) inside a C frame
     that allocated a `caml__roots_block` without exception-safe unwind cleanup: *)
  let eval_ffi_callback_unwind_buggy
      ~(outer_frames : roots_frame list)
      ~(c_frame : roots_frame)
      ~(raises_exn : bool) : (string, string) result =
    let st = { caml_local_roots = c_frame :: outer_frames } in
    if raises_exn then begin
      (* C stack frame is popped by unwinding, but `CAMLreturn` was skipped! *)
      c_frame.on_live_stack <- false;
      (* Next GC scans `st.caml_local_roots`: *)
      match List.find_opt (fun f -> not f.on_live_stack) st.caml_local_roots with
      | Some dangling ->
          Error
            (Printf.sprintf
               "DANGLING_CAML_LOCAL_ROOTS_ON_POPPED_C_FRAME:frame_%d"
               dangling.frame_id)
      | None -> Ok "Roots_valid"
    end else begin
      (* Normal return executes `CAMLreturn`: *)
      st.caml_local_roots <- outer_frames;
      c_frame.on_live_stack <- false;
      Ok "Normal_return_roots_popped"
    end

  (* Repaired C FFI wrapper using `caml_callback_exn` + `Is_exception_result`:
     Captures the exception as an encoded value (`Make_exception_result`),
     executes `CAMLreturn` (`caml_local_roots = caml__frame.next`) while the C
     frame is still live, and only then re-raises or returns cleanly. *)
  let eval_ffi_callback_unwind_repaired
      ~(outer_frames : roots_frame list)
      ~(c_frame : roots_frame)
      ~(raises_exn : bool) : (string, string) result =
    let saved_roots = outer_frames in
    let st = { caml_local_roots = c_frame :: saved_roots } in
    let exn_result = raises_exn in
    (* `CAMLreturn` restores `st.caml_local_roots <- saved_roots` BEFORE popping C frame *)
    st.caml_local_roots <- saved_roots;
    c_frame.on_live_stack <- false;
    match List.find_opt (fun f -> not f.on_live_stack) st.caml_local_roots with
    | Some dangling ->
        Error
          (Printf.sprintf
             "Impossible_dangling_frame_%d"
             dangling.frame_id)
    | None ->
        if exn_result then
          Ok "Exception_cleanly_caught_via_caml_callback_exn_and_roots_restored"
        else
          Ok "Normal_return_roots_popped"
end
