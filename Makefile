# ==============================================================================
# Mothman SC2 Bot & s2protocol-sidecar Makefile
# ==============================================================================
# Pure-Racket SC2 bot runtime, test suites, AI Arena BotZip packager,
# and Rust s2protocol-sidecar replay analyzer / Web UI daemon.
# ==============================================================================

SHELL := /bin/bash
.SHELLFLAGS := -eu -o pipefail -c

RACKET ?= $(shell command -v racket 2>/dev/null || echo racket)
CARGO  ?= $(shell command -v cargo 2>/dev/null || echo cargo)
SIDECAR_MANIFEST := crates/s2protocol-sidecar/Cargo.toml

.DEFAULT_GOAL := help
.PHONY: help all test full-test sidecar zips status clean

help:
	@printf "Mothman SC2 Bot — Available Make Targets:\n"
	@printf "  make test       Run fast Racket test suites (run-all, sc2-protobuf-ws, typed-commands)\n"
	@printf "  make full-test  Run full Racket suites (--full) + Rust s2protocol-sidecar tests\n"
	@printf "  make sidecar    Build release s2protocol-sidecar binary\n"
	@printf "  make zips       Rebuild ladder/Mothman-{X,Z,T,P}.zip BotZip archives\n"
	@printf "  make status     Check live AI Arena bot status via aiarena-api-client.rkt\n"
	@printf "  make clean      Remove compiled Racket bytecode caches\n"

all: test

test:
	$(RACKET) tests/run-all-tests.rkt
	$(RACKET) tests/sc2-protobuf-ws-test.rkt
	$(RACKET) tests/typed-commands-test.rkt

full-test:
	$(RACKET) tests/run-all-tests.rkt --full
	$(RACKET) tests/sc2-protobuf-ws-test.rkt
	$(RACKET) tests/typed-commands-test.rkt
	$(CARGO) test --manifest-path $(SIDECAR_MANIFEST)

sidecar:
	$(CARGO) build --release --manifest-path $(SIDECAR_MANIFEST)

zips:
	$(RACKET) ladder/build-aiarena-zip.rkt --all-races

status:
	$(RACKET) tools/aiarena-api-client.rkt --status

clean:
	find lib sim tests tools ladder -type d -name compiled -prune -exec rm -rf {} +
	@printf "Removed compiled Racket bytecode caches.\n"
