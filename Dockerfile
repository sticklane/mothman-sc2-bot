# ==============================================================================
# LakefillQ Self-Contained Artifact Evaluation Container
# ==============================================================================
# Single-image Debian Bookworm environment providing:
#   - Python 3.11 + virtualenv (z3-solver, qiskit, qiskit-aer, stim, pymatching, pyzx)
#   - Racket + Raco (with #lang lakefillq linked locally)
#   - Lean 4.35.0 via elan (leanprover/lean4:v4.35.0)
#   - GHC (Haskell) & OCaml compilers
#   - TeX Live (acmart, quantikz, BibTeX)
#
# Build & Smoke Check (< 35s runtime):
#   docker build -t lakefillq-ae .
#   docker run --rm lakefillq-ae
#
# Interactive Explorer & Full Reproduction:
#   docker run --rm lakefillq-ae make explore
#   docker run --rm lakefillq-ae make full
# ==============================================================================

FROM debian:bookworm-slim

ENV DEBIAN_FRONTEND=noninteractive \
    LANG=C.UTF-8 \
    LC_ALL=C.UTF-8 \
    PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    TMPDIR=/workspace/.persistent_tmp \
    ELAN_HOME=/opt/elan \
    VIRTUAL_ENV=/opt/lakefillq-venv

RUN mkdir -p /workspace/.persistent_tmp && \
    apt-get update && \
    apt-get install -y --no-install-recommends \
      bash \
      build-essential \
      ca-certificates \
      curl \
      ghc \
      git \
      make \
      ocaml \
      python3 \
      python3-dev \
      python3-pip \
      python3-venv \
      racket \
      texlive-bibtex-extra \
      texlive-latex-base \
      texlive-latex-extra \
      texlive-latex-recommended \
      texlive-science && \
    rm -rf /var/lib/apt/lists/*

# Install Lean 4.35.0 toolchain via elan
RUN curl -sSf https://raw.githubusercontent.com/leanprover/elan/master/elan-init.sh | \
    sh -s -- -y --no-modify-path --default-toolchain leanprover/lean4:v4.35.0

# Create isolated Python virtual environment and install simulator & SMT packages
RUN python3 -m venv "${VIRTUAL_ENV}" && \
    "${VIRTUAL_ENV}/bin/pip" install --no-cache-dir --upgrade pip setuptools wheel && \
    "${VIRTUAL_ENV}/bin/pip" install --no-cache-dir \
      numpy \
      scipy \
      z3-solver \
      qiskit \
      qiskit-aer \
      stim \
      pymatching \
      pyzx

ENV PATH="${VIRTUAL_ENV}/bin:${ELAN_HOME}/bin:${PATH}"

WORKDIR /workspace
COPY . /workspace

# Ensure persistent scratch exists and link #lang lakefillq into Racket
RUN mkdir -p /workspace/.persistent_tmp && \
    raco pkg install --user --link --no-setup /workspace/lakefillq && \
    rm -rf /workspace/.lakefillq_tmp

CMD ["make", "quick"]
