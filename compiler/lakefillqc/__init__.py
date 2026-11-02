"""
compiler/lakefillqc/__init__.py
===============================
LakefillQ Unified Compiler & Symbolic $k$-Inductive `QSub` (`Laws U1-U4`) Package.
"""

from compiler.lakefillqc.codegen import compile_and_emit
from compiler.lakefillqc.infer_qsub import (
    LoopRoundSpec,
    QPhysEffectGrade,
    QSubInferenceResult,
    build_aes128_round_spec,
    build_aes256_round_spec,
    build_chacha20_round_spec,
    build_cross_loop_session_pipeline_spec,
    build_deep_permutation_round_spec,
    build_keccak_f200_round_spec,
    build_two_round_coupled_sponge_spec,
    infer_for_fold_loop_sexpr,
    infer_inductive_loop_qsub,
    infer_loop_qsub_auto_escalate,
    infer_module_qsub,
)
from compiler.lakefillqc.parser import (
    ForFoldLoopAST,
    LFQParsedModule,
    parse_lfq_file,
    parse_lfq_source,
)
from compiler.lakefillqc.typecheck import (
    typecheck_for_fold_spec,
    typecheck_lfq_module,
)

__all__ = [
    "ForFoldLoopAST",
    "LFQParsedModule",
    "LoopRoundSpec",
    "QPhysEffectGrade",
    "QSubInferenceResult",
    "build_aes128_round_spec",
    "build_aes256_round_spec",
    "build_chacha20_round_spec",
    "build_cross_loop_session_pipeline_spec",
    "build_deep_permutation_round_spec",
    "build_keccak_f200_round_spec",
    "build_two_round_coupled_sponge_spec",
    "compile_and_emit",
    "infer_for_fold_loop_sexpr",
    "infer_inductive_loop_qsub",
    "infer_loop_qsub_auto_escalate",
    "infer_module_qsub",
    "parse_lfq_file",
    "parse_lfq_source",
    "typecheck_for_fold_spec",
    "typecheck_lfq_module",
]
