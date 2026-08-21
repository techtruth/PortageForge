.DEFAULT_GOAL := help

SSH_PUBLIC_KEY ?=
SETUP_ARGS := $(strip $(SSH_PUBLIC_KEY))

.PHONY: help setup run export-target-state check

help:
	@printf '%s\n' 'PortageForge targets:'
	@printf '%s\n' '  make setup                         Prepare images/ and vm/ directories'
	@printf '%s\n' '  make setup SSH_PUBLIC_KEY=key.pub  Prepare using a specific SSH public key'
	@printf '%s\n' '  make run                           Boot the QEMU builder VM'
	@printf '%s\n' '  make export-target-state           Export target state on a Gentoo client'
	@printf '%s\n' '  make check                         Syntax-check project shell scripts'

setup:
	./scripts/setup-portageforge-builder $(SETUP_ARGS)

run:
	./scripts/run-portageforge-builder

export-target-state:
	./scripts/export-target-state

check:
	bash -n ./scripts/setup-portageforge-builder ./scripts/run-portageforge-builder ./scripts/export-target-state ./scripts/portageforge-builder
