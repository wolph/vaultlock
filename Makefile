SHELL := /bin/bash
REPO_ROOT := $(abspath $(dir $(lastword $(MAKEFILE_LIST))))
BIN_DIR ?= $(HOME)/bin

export VAULTLOCK_INSTALL_REPO_ROOT := $(REPO_ROOT)
export VAULTLOCK_INSTALL_BIN_DIR := $(BIN_DIR)

.PHONY: test check install

test:
	tests/vaultlock-test.sh bin/vaultlock
	tests/vaultlock-cli-test.sh bin/vaultlock
	tests/install-test.sh

check: test
	/bin/bash -n bin/vaultlock tests/vaultlock-test.sh tests/vaultlock-cli-test.sh tests/install-test.sh
	shellcheck bin/vaultlock tests/vaultlock-test.sh tests/vaultlock-cli-test.sh tests/install-test.sh

install: check
	@set -euo pipefail; \
	repo_root=$${VAULTLOCK_INSTALL_REPO_ROOT:?}; \
	bin_dir=$${VAULTLOCK_INSTALL_BIN_DIR:?}; \
	sources=(bin/vaultlock tests/vaultlock-test.sh); \
	names=(vaultlock vaultlock-test.sh); \
	source_paths=(); \
	source_identities=(); \
	target_paths=(); \
	target_kinds=(); \
	target_identities=(); \
	baseline_commits=(); \
	stage_directories=(); \
	stage_links=(); \
	stage_identities=(); \
	cleanup_install_stages() { \
		local index stage link expected_source; \
		for ((index=0; index<$${#stage_directories[@]}; index++)); do \
			stage=$${stage_directories[$$index]-}; \
			link=$${stage_links[$$index]-}; \
			expected_source=$${source_paths[$$index]-}; \
			if [[ -n "$$link" && -L "$$link" \
				&& "$$(/usr/bin/readlink "$$link")" == "$$expected_source" ]]; then \
				/bin/rm "$$link"; \
			fi; \
			if [[ -n "$$stage" && -d "$$stage" && ! -L "$$stage" ]]; then \
				/bin/rmdir "$$stage" 2>/dev/null || true; \
			fi; \
		done; \
	}; \
	finish_install() { \
		local install_status=$$?; \
		trap - EXIT HUP INT TERM; \
		cleanup_install_stages; \
		exit "$$install_status"; \
	}; \
	trap finish_install EXIT; \
	trap 'exit 129' HUP; \
	trap 'exit 130' INT; \
	trap 'exit 143' TERM; \
	[[ "$$repo_root" == /* && -d "$$repo_root" && ! -L "$$repo_root" ]] \
		|| { printf 'invalid repository root: %s\n' "$$repo_root" >&2; exit 1; }; \
	if [[ -L "$$bin_dir" || ( -e "$$bin_dir" && ! -d "$$bin_dir" ) ]]; then \
		printf 'refusing unsafe BIN_DIR: %s\n' "$$bin_dir" >&2; \
		exit 1; \
	fi; \
	for ((index=0; index<$${#sources[@]}; index++)); do \
		source=$${sources[$$index]}; \
		name=$${names[$$index]}; \
		source_path=$$repo_root/$$source; \
		target=$$bin_dir/$$name; \
		[[ -f "$$source_path" && ! -L "$$source_path" \
			&& -r "$$source_path" && -x "$$source_path" ]] \
			|| { printf 'refusing invalid repository source: %s\n' "$$source_path" >&2; exit 1; }; \
		first_commit=$$(/usr/bin/git -C "$$repo_root" log --diff-filter=A \
			--format=%H -- "$$source" | /usr/bin/tail -n 1); \
		[[ -n "$$first_commit" ]] \
			|| { printf 'no baseline commit for %s\n' "$$source" >&2; exit 1; }; \
		/usr/bin/git -C "$$repo_root" cat-file -e "$$first_commit:$$source" \
			|| { printf 'missing baseline blob for %s\n' "$$source" >&2; exit 1; }; \
		baseline_type=$$(/usr/bin/git -C "$$repo_root" cat-file -t \
			"$$first_commit:$$source"); \
		[[ "$$baseline_type" == blob ]] \
			|| { printf 'invalid baseline blob for %s\n' "$$source" >&2; exit 1; }; \
		source_paths[$$index]=$$source_path; \
		source_identities[$$index]=$$(/usr/bin/stat -f '%d:%i' "$$source_path"); \
		target_paths[$$index]=$$target; \
		baseline_commits[$$index]=$$first_commit; \
		if [[ -L "$$target" ]]; then \
			current=$$(/usr/bin/readlink "$$target"); \
			[[ "$$current" == "$$source_path" ]] \
				|| { printf 'refusing unexpected symlink: %s -> %s\n' "$$target" "$$current" >&2; exit 1; }; \
			target_kinds[$$index]=link; \
			target_identities[$$index]=$$(/usr/bin/stat -f '%d:%i' "$$target"); \
		elif [[ -f "$$target" ]]; then \
			/usr/bin/git -C "$$repo_root" show "$$first_commit:$$source" \
				| /usr/bin/cmp -s - "$$target" \
				|| { printf 'refusing modified target: %s\n' "$$target" >&2; exit 1; }; \
			target_kinds[$$index]=regular; \
			target_identities[$$index]=$$(/usr/bin/stat -f '%d:%i' "$$target"); \
		elif [[ -e "$$target" ]]; then \
			printf 'refusing unsupported target: %s\n' "$$target" >&2; \
			exit 1; \
		else \
			target_kinds[$$index]=absent; \
			target_identities[$$index]=; \
		fi; \
	done; \
	/bin/mkdir -p "$$bin_dir"; \
	[[ -d "$$bin_dir" && ! -L "$$bin_dir" ]] \
		|| { printf 'BIN_DIR changed during installation: %s\n' "$$bin_dir" >&2; exit 1; }; \
	for ((index=0; index<$${#sources[@]}; index++)); do \
		stage=$$(/usr/bin/mktemp -d \
			"$$bin_dir/.vaultlock-install.$${names[$$index]}.XXXXXX"); \
		stage_directories[$$index]=$$stage; \
		/bin/chmod 700 "$$stage"; \
		stage_links[$$index]=$$stage/link; \
		/bin/ln -s "$${source_paths[$$index]}" "$${stage_links[$$index]}"; \
		stage_identities[$$index]=$$(/usr/bin/stat -f '%d:%i' \
			"$${stage_links[$$index]}"); \
	done; \
	for ((index=0; index<$${#sources[@]}; index++)); do \
		target=$${target_paths[$$index]}; \
		source_path=$${source_paths[$$index]}; \
		[[ -f "$$source_path" && ! -L "$$source_path" \
			&& -r "$$source_path" && -x "$$source_path" \
			&& "$$(/usr/bin/stat -f '%d:%i' "$$source_path")" == "$${source_identities[$$index]}" ]] \
			|| { printf 'repository source changed before installation: %s\n' "$$source_path" >&2; exit 1; }; \
		case "$${target_kinds[$$index]}" in \
			absent) \
				[[ ! -e "$$target" && ! -L "$$target" ]] \
					|| { printf 'target changed before installation: %s\n' "$$target" >&2; exit 1; } \
				;; \
			link) \
				[[ -L "$$target" \
					&& "$$(/usr/bin/readlink "$$target")" == "$$source_path" \
					&& "$$(/usr/bin/stat -f '%d:%i' "$$target")" == "$${target_identities[$$index]}" ]] \
					|| { printf 'target changed before installation: %s\n' "$$target" >&2; exit 1; } \
				;; \
			regular) \
				[[ -f "$$target" && ! -L "$$target" \
					&& "$$(/usr/bin/stat -f '%d:%i' "$$target")" == "$${target_identities[$$index]}" ]] \
					|| { printf 'target changed before installation: %s\n' "$$target" >&2; exit 1; }; \
				/usr/bin/git -C "$$repo_root" show \
					"$${baseline_commits[$$index]}:$${sources[$$index]}" \
					| /usr/bin/cmp -s - "$$target" \
					|| { printf 'target changed before installation: %s\n' "$$target" >&2; exit 1; } \
				;; \
		esac; \
	done; \
	for ((index=0; index<$${#sources[@]}; index++)); do \
		target=$${target_paths[$$index]}; \
		source_path=$${source_paths[$$index]}; \
		stage_link=$${stage_links[$$index]}; \
		[[ -f "$$source_path" && ! -L "$$source_path" \
			&& -r "$$source_path" && -x "$$source_path" \
			&& "$$(/usr/bin/stat -f '%d:%i' "$$source_path")" == "$${source_identities[$$index]}" ]] \
			|| { printf 'repository source changed before replacement: %s\n' "$$source_path" >&2; exit 1; }; \
		[[ -L "$$stage_link" \
			&& "$$(/usr/bin/readlink "$$stage_link")" == "$$source_path" \
			&& "$$(/usr/bin/stat -f '%d:%i' "$$stage_link")" == "$${stage_identities[$$index]}" ]] \
			|| { printf 'staged link changed before installation: %s\n' "$$stage_link" >&2; exit 1; }; \
		case "$${target_kinds[$$index]}" in \
			absent) \
				[[ ! -e "$$target" && ! -L "$$target" ]] \
					|| { printf 'target changed before replacement: %s\n' "$$target" >&2; exit 1; } \
				;; \
			link) \
				[[ -L "$$target" \
					&& "$$(/usr/bin/readlink "$$target")" == "$$source_path" \
					&& "$$(/usr/bin/stat -f '%d:%i' "$$target")" == "$${target_identities[$$index]}" ]] \
					|| { printf 'target changed before replacement: %s\n' "$$target" >&2; exit 1; } \
				;; \
			regular) \
				[[ -f "$$target" && ! -L "$$target" \
					&& "$$(/usr/bin/stat -f '%d:%i' "$$target")" == "$${target_identities[$$index]}" ]] \
					|| { printf 'target changed before replacement: %s\n' "$$target" >&2; exit 1; }; \
				/usr/bin/git -C "$$repo_root" show \
					"$${baseline_commits[$$index]}:$${sources[$$index]}" \
					| /usr/bin/cmp -s - "$$target" \
					|| { printf 'target changed before replacement: %s\n' "$$target" >&2; exit 1; } \
				;; \
		esac; \
		/bin/mv -f "$$stage_link" "$$target"; \
		[[ -L "$$target" \
			&& "$$(/usr/bin/readlink "$$target")" == "$$source_path" ]] \
			|| { printf 'installed link verification failed: %s\n' "$$target" >&2; exit 1; }; \
		/bin/rmdir "$${stage_directories[$$index]}"; \
		stage_directories[$$index]=; \
		stage_links[$$index]=; \
		printf 'installed %s -> %s\n' "$$target" "$$source_path"; \
	done
