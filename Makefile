SHELL := /bin/sh
GO ?= go
BIN_DIR ?= $(HOME)/bin
VERSION ?= dev
export VAULTLOCK_BUILD_VERSION = $(value VERSION)
TARGET_OS := $(shell $(GO) env GOOS)
TARGET_ARCH := $(shell $(GO) env GOARCH)
ARCHIVE := build/vaultlock-$(TARGET_OS)-$(TARGET_ARCH).tar.gz

ifeq ($(origin BIN_DIR),file)
export VAULTLOCK_INSTALL_BIN_DIR_MODE := default-home
else
export VAULTLOCK_INSTALL_BIN_DIR_MODE := explicit
endif
export VAULTLOCK_INSTALL_BIN_DIR = $(value BIN_DIR)

.PHONY: build dist test test-ci check check-ci lint check-format install clean

build:
	CGO_ENABLED=0 $(GO) build -trimpath -ldflags "-X github.com/wolph/vaultlock/internal/cli.Version=$$VAULTLOCK_BUILD_VERSION" -o build/vaultlock ./cmd/vaultlock

dist: build
	tar -czf $(ARCHIVE) -C build vaultlock
	cd build && shasum -a 256 $(notdir $(ARCHIVE)) > $(notdir $(ARCHIVE)).sha256

test test-ci:
	$(GO) test ./...

lint:
	$(GO) vet ./...

check-format:
	@test -z "$$(gofmt -l cmd internal)" || { echo 'Go formatting needed' >&2; exit 1; }

check check-ci: test lint check-format build

install: check
	$(GO) run ./cmd/vaultlock-install build/vaultlock

clean:
	rm -rf build
