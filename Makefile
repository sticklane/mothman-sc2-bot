# ==============================================================================
# LakefillQ Standalone Open-Source Artifact Evaluation Makefile
# ==============================================================================
# Automatically discovers Python, Racket, Raco, and Lean 4.35.0 toolchains
# without hardcoded user paths, and routes all temporary files to a persistent
# scratch directory (never ephemeral root scratch mounts).
# ==============================================================================

SHELL := /bin/bash
.SHELLFLAGS := -eu -o pipefail -c

# Persistent scratch directory discovery (cleaned on exit when workspace-local)
HOST_PERSISTENT_TMP := /home/antigravity/toolchains/tmp
LOCAL_AE_TMP        := $(CURDIR)/.lakefillq_tmp

ifneq ($(wildcard $(HOST_PERSISTENT_TMP)),)
  TMPDIR ?= $(HOST_PERSISTENT_TMP)
else
  TMPDIR ?= $(LOCAL_AE_TMP)
endif
export TMPDIR
export PYTHONDONTWRITEBYTECODE := 1

# Dynamic toolchain discovery: check PATH (verifying scientific deps for Python),
# then local/parent virtualenvs, then shared persistent toolchain installations.
PYTHON ?= $(shell \
  if command -v python3 >/dev/null 2>&1 && python3 -c "import z3, stim, qiskit" >/dev/null 2>&1; then \
    command -v python3; \
  elif [ -x "$(CURDIR)/.venv/bin/python" ]; then \
    echo "$(CURDIR)/.venv/bin/python"; \
  elif [ -x "$(CURDIR)/../.venv/bin/python" ]; then \
    echo "$(CURDIR)/../.venv/bin/python"; \
  elif [ -x "/opt/lakefillq-venv/bin/python" ]; then \
    echo "/opt/lakefillq-venv/bin/python"; \
  elif [ -x "/home/antigravity/toolchains/quantum-venv/bin/python" ]; then \
    echo "/home/antigravity/toolchains/quantum-venv/bin/python"; \
  elif command -v python3 >/dev/null 2>&1; then \
    command -v python3; \
  else \
    command -v python; \
  fi)

RACKET ?= $(shell \
  if command -v racket >/dev/null 2>&1; then \
    command -v racket; \
  elif [ -x "$(HOME)/toolchains/racket-p36t2/racket/bin/racket" ]; then \
    echo "$(HOME)/toolchains/racket-p36t2/racket/bin/racket"; \
  elif [ -x "/home/antigravity/toolchains/racket-p36t2/racket/bin/racket" ]; then \
    echo "/home/antigravity/toolchains/racket-p36t2/racket/bin/racket"; \
  else \
    echo "racket"; \
  fi)

RACO ?= $(shell \
  if command -v raco >/dev/null 2>&1; then \
    command -v raco; \
  elif [ -x "$(HOME)/toolchains/racket-p36t2/racket/bin/raco" ]; then \
    echo "$(HOME)/toolchains/racket-p36t2/racket/bin/raco"; \
  elif [ -x "/home/antigravity/toolchains/racket-p36t2/racket/bin/raco" ]; then \
    echo "/home/antigravity/toolchains/racket-p36t2/racket/bin/raco"; \
  else \
    echo "raco"; \
  fi)

LEAN ?= $(shell \
  if command -v lean >/dev/null 2>&1; then \
    command -v lean; \
  elif [ -x "$(HOME)/.elan/bin/lean" ]; then \
    echo "$(HOME)/.elan/bin/lean"; \
  elif [ -x "/opt/elan/bin/lean" ]; then \
    echo "/opt/elan/bin/lean"; \
  elif [ -x "$(HOME)/toolchains/lean4-p36t4/lean-4.35.0-linux/bin/lean" ]; then \
    echo "$(HOME)/toolchains/lean4-p36t4/lean-4.35.0-linux/bin/lean"; \
  elif [ -x "/home/antigravity/toolchains/lean4-p36t4/lean-4.35.0-linux/bin/lean" ]; then \
    echo "/home/antigravity/toolchains/lean4-p36t4/lean-4.35.0-linux/bin/lean"; \
  elif [ -x "/home/antigravity/toolchains/lean4-p36t2/lean-4.35.0-linux/bin/lean" ]; then \
    echo "/home/antigravity/toolchains/lean4-p36t2/lean-4.35.0-linux/bin/lean"; \
  else \
    echo "lean"; \
  fi)

EXTRA_PATH := $(dir $(PYTHON)):$(dir $(RACKET)):$(dir $(LEAN))
ifneq ($(wildcard $(CURDIR)/../.venv/bin),)
  EXTRA_PATH := $(abspath $(CURDIR)/../.venv/bin):$(EXTRA_PATH)
endif
ifneq ($(wildcard $(CURDIR)/.venv/bin),)
  EXTRA_PATH := $(abspath $(CURDIR)/.venv/bin):$(EXTRA_PATH)
endif
export PATH := $(EXTRA_PATH):$(PATH)
export LAKEFILLQ_PYTHON := $(PYTHON)
export LAKEFILLQ_RACKET := $(RACKET)
export LAKEFILLQ_RACO   := $(RACO)
export LAKEFILLQ_LEAN   := $(LEAN)

.DEFAULT_GOAL := help
.PHONY: help quick examples proofs rtl paper explore full clean

help:
	@printf "========================================================================================\n"
	@printf "  LakefillQ Artifact Evaluation Bundle — Make Targets\n"
	@printf "========================================================================================\n"
	@printf "  make help      Display this target overview and resolved toolchain paths\n"
	@printf "  make quick     Fast (< 35s) end-to-end smoke check across compiler, RTL, proofs, lints\n"
	@printf "  make examples  Compile all .lfq modules in examples/ to dynamic OpenQASM 3.0 and Stim\n"
	@printf "  make proofs    Kernel-check standalone LakefillQ and master Lean 4.35.0 proof modules\n"
	@printf "  make rtl       Run 500 MHz 0-DSP SystemVerilog/DSLX Z3 miters and 80k-cycle Stim cosim\n"
	@printf "  make paper     Cross-check 125 quantitative claims, 21 formal labels, and LaTeX/BibTeX\n"
	@printf "  make explore   Launch terminal explorer summary of SOTA tables, QPhysGrade, and proofs\n"
	@printf "  make full      Complete reproduction across all compiler, simulator, RTL, & proof checks\n"
	@printf "  make clean     Remove workspace-local scratch directories and bytecode caches\n"
	@printf "----------------------------------------------------------------------------------------\n"
	@printf "  Detected Toolchains:\n"
	@printf "    PYTHON : %s\n" "$(PYTHON)"
	@printf "    RACKET : %s\n" "$(RACKET)"
	@printf "    RACO   : %s\n" "$(RACO)"
	@printf "    LEAN   : %s\n" "$(LEAN)"
	@printf "    TMPDIR : %s\n" "$(TMPDIR)"
	@printf "========================================================================================\n"

quick:
	@mkdir -p "$(TMPDIR)"
	@status=0; \
	"$(PYTHON)" "$(CURDIR)/ae/run_artifact_evaluation.py" --mode quick || status=$$?; \
	rm -rf "$(LOCAL_AE_TMP)"; \
	exit $$status

examples:
	@mkdir -p "$(TMPDIR)"
	@status=0; \
	"$(PYTHON)" "$(CURDIR)/ae/run_artifact_evaluation.py" --examples || status=$$?; \
	rm -rf "$(LOCAL_AE_TMP)"; \
	exit $$status

proofs:
	@mkdir -p "$(TMPDIR)"
	@status=0; \
	"$(PYTHON)" "$(CURDIR)/ae/run_artifact_evaluation.py" --proofs || status=$$?; \
	rm -rf "$(LOCAL_AE_TMP)"; \
	exit $$status

rtl:
	@mkdir -p "$(TMPDIR)"
	@status=0; \
	"$(PYTHON)" "$(CURDIR)/reproducers/verify_lakefillq_0dsp_rtl_z3_and_stim_cosim.py" || status=$$?; \
	rm -rf "$(LOCAL_AE_TMP)"; \
	exit $$status

paper:
	@mkdir -p "$(TMPDIR)"
	@status=0; \
	"$(PYTHON)" "$(CURDIR)/reproducers/verify_lakefillq_paper_claims_and_latex_manifest.py" || status=$$?; \
	rm -rf "$(LOCAL_AE_TMP)"; \
	exit $$status

explore:
	@mkdir -p "$(TMPDIR)"
	@status=0; \
	"$(PYTHON)" "$(CURDIR)/ae/lakefillq_explorer.py" --summary || status=$$?; \
	rm -rf "$(LOCAL_AE_TMP)"; \
	exit $$status

full:
	@mkdir -p "$(TMPDIR)"
	@status=0; \
	"$(PYTHON)" "$(CURDIR)/ae/run_artifact_evaluation.py" --mode full || status=$$?; \
	rm -rf "$(LOCAL_AE_TMP)"; \
	exit $$status

clean:
	@rm -rf "$(LOCAL_AE_TMP)" "$(CURDIR)/ae/__pycache__"
	@printf "Cleaned workspace-local scratch directories.\n"
