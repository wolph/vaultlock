SHELL := /bin/bash
REPO_ROOT := $(abspath $(dir $(lastword $(MAKEFILE_LIST))))

ifeq ($(origin BIN_DIR), undefined)
VAULTLOCK_INSTALL_BIN_DIR_MODE := default-home
VAULTLOCK_INSTALL_HOME = $(value HOME)
else
VAULTLOCK_INSTALL_BIN_DIR_MODE := explicit
VAULTLOCK_INSTALL_BIN_DIR = $(value BIN_DIR)
endif

export VAULTLOCK_INSTALL_REPO_ROOT := $(REPO_ROOT)
export VAULTLOCK_INSTALL_BIN_DIR_MODE
export VAULTLOCK_INSTALL_BIN_DIR
export VAULTLOCK_INSTALL_HOME
unexport BIN_DIR

.PHONY: test check install

test:
	tests/vaultlock-test.sh bin/vaultlock
	tests/vaultlock-time-test.sh bin/vaultlock
	tests/vaultlock-cli-test.sh bin/vaultlock
	tests/install-test.sh

check: test
	/bin/bash -n bin/vaultlock scripts/install.sh tests/vaultlock-test.sh tests/vaultlock-time-test.sh tests/vaultlock-cli-test.sh tests/install-test.sh
	shellcheck bin/vaultlock scripts/install.sh tests/vaultlock-test.sh tests/vaultlock-time-test.sh tests/vaultlock-cli-test.sh tests/install-test.sh

install: check
	@scripts/install.sh
