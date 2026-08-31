BASH_BIN ?= $(shell if [ -x /opt/homebrew/bin/bash ]; then echo /opt/homebrew/bin/bash; elif [ -x /usr/local/bin/bash ]; then echo /usr/local/bin/bash; else command -v bash; fi)
SHELL := $(BASH_BIN)

AUDL_PYTHON_BIN ?= python3
ENV_AUDL_BIN_PATH := $(shell if [ -f .env ]; then set -a; . ./.env >/dev/null 2>&1; printf '%s' "$${AUDL_BIN_PATH:-}"; fi)
PREFIX ?= $(if $(AUDL_BIN_PATH),$(AUDL_BIN_PATH),$(if $(ENV_AUDL_BIN_PATH),$(ENV_AUDL_BIN_PATH),$(HOME)/.local/bin))
# Installable product scripts. The source audit is developer-only.
INSTALLABLE_SCRIPTS := $(filter-out audlint-source-audit.sh,$(sort $(notdir $(wildcard bin/*.sh))))
INSTALLABLE_ALIASES := \
	auz:audlint-analyze.sh \
	auv:audlint-value.sh \
	aua:cover_album.sh \
	auq:qty_compare.sh \
	aus:audlint-spectre.sh
LEGACY_ALIAS_TRASH := aul
SHELLCHECK_TARGETS ?= bin lib/sh test/sh
SHFMT_TARGETS ?= test/sh
SHFMT_EXTRA ?= install.sh
SHELLCHECK_OPTS ?= -e SC2004,SC2015,SC2029,SC2034,SC2162,SC2178,SC2181,SC2221,SC2222,SC2235

FAST_TEST_FILES := \
	test/legacy/test_legacy_qty_compare_cli.py \
	test/test_audio_probe_smoke.py \
	test/test_audlint_analyze_logic.py \
	test/test_audlint_dataset_smoke.py \
	test/test_audlint_doctor_smoke.py \
	test/test_audlint_source_audit_smoke.py \
	test/test_audlint_task_smoke.py \
	test/test_audlint_value_smoke.py \
	test/test_bootstrap_portability.py \
	test/test_bootstrap_tty.py \
	test/test_deps_path_smoke.py \
	test/test_dr_grade.py \
	test/test_install_sh_smoke.py \
	test/test_makefile_contract.py \
	test/test_lyrics_smoke.py \
	test/test_player_content_creator.py \
	test/test_profile_norm.py \
	test/test_secure_backup.py \
	test/test_spectre_calibration_cases.py \
	test/test_spectre_cli_smoke.py \
	test/test_spectre_image.py \
	test/test_sqlite_profile_normalization.py \
	test/test_sqlite_query_plan_smoke.py \
	test/test_sync_music_smoke.py

INTEGRATION_TEST_FILES := \
	test/legacy/test_legacy_audlint_task_db.py \
	test/legacy/test_legacy_boost_audio_cli_smoke.py \
	test/legacy/test_legacy_tags_scripts.py \
	test/test_any2flac_smoke.py \
	test/test_audlint_analyze_cache_smoke.py \
	test/test_audlint_analyze_corpus_baseline.py \
	test/test_audlint_analyze_corpus_benchmark.py \
	test/test_audlint_analyze_corpus_smoke.py \
	test/test_audlint_maintain_smoke.py \
	test/test_cover_smoke.py \
	test/test_cue2flac_smoke.py \
	test/test_dff2flac_smoke.py \
	test/test_library_browser_smoke.py \
	test/test_ui_regression.py

.PHONY: help install uninstall relink install-env lint fmt-check bash5-check test test-integration test-all test-spectre source-audit check db-reset

help:
	@printf "%s\n" \
		"Targets:" \
		"  install      Symlink bin/*.sh scripts + aliases (auz/auv/aua/auq/aus) into PREFIX ($(PREFIX))" \
		"  uninstall    Remove installed script + alias symlinks from PREFIX ($(PREFIX))" \
		"  relink       Recreate symlinks in PREFIX" \
		"  install-env  Generate .env via install.sh" \
		"  lint         Run shellcheck on shell scripts" \
		"  fmt-check    Run shfmt -d on shell scripts" \
		"  bash5-check  Validate Bash 5 shebang/parse consistency" \
		"  test         Run the fast Python development suite" \
		"  test-integration Run integration and deep-regression Python tests" \
		"  test-all     Run every supported Python test once (release suite)" \
		"  test-spectre Run spectre.sh smoke tests" \
		"  source-audit Audit commit candidates for prohibited content" \
		"  check        Run lint + fmt-check + bash5-check + test-all + source-audit" \
		"  db-reset     Truncate album_quality + scan_roadmap (requires AUDL_DB_PATH env var)"

install:
	@mkdir -p "$(PREFIX)"
	@for script in $(INSTALLABLE_SCRIPTS); do \
		ln -sfn "$(abspath bin)/$$script" "$(PREFIX)/$$script"; \
	done
	@for pair in $(INSTALLABLE_ALIASES); do \
		alias_name="$${pair%%:*}"; \
		target_script="$${pair#*:}"; \
		ln -sfn "$(abspath bin)/$$target_script" "$(PREFIX)/$$alias_name"; \
	done

uninstall:
	@for script in $(INSTALLABLE_SCRIPTS); do \
		rm -f "$(PREFIX)/$$script"; \
	done
	@for pair in $(INSTALLABLE_ALIASES); do \
		alias_name="$${pair%%:*}"; \
		rm -f "$(PREFIX)/$$alias_name"; \
	done
	@for alias_name in $(LEGACY_ALIAS_TRASH); do \
		rm -f "$(PREFIX)/$$alias_name"; \
	done

relink: uninstall install

install-env:
	@./install.sh

lint:
	@command -v shellcheck >/dev/null 2>&1 || { echo "Missing dependency: shellcheck"; exit 2; }
	@shellcheck $(SHELLCHECK_OPTS) $$(find $(SHELLCHECK_TARGETS) -type f -name '*.sh' | sort)

fmt-check:
	@command -v shfmt >/dev/null 2>&1 || { echo "Missing dependency: shfmt"; exit 2; }
	@shfmt -d $$(find $(SHFMT_TARGETS) -type f -name '*.sh' | sort) $(SHFMT_EXTRA)

bash5-check:
	@test/sh/bash5_consistency.sh lib/sh bin

test-spectre:
	@$(AUDL_PYTHON_BIN) -m unittest discover -s test -p 'test_spectre_cli_smoke.py' -v

test:
	@$(AUDL_PYTHON_BIN) -m unittest $(FAST_TEST_FILES)

test-integration:
	@$(AUDL_PYTHON_BIN) -m unittest $(INTEGRATION_TEST_FILES)

test-all:
	@$(AUDL_PYTHON_BIN) -m unittest $(FAST_TEST_FILES) $(INTEGRATION_TEST_FILES)

source-audit:
	@bin/audlint-source-audit.sh

# The recipe, rather than parallel prerequisites, keeps the authoritative audit
# strictly after the complete Python suite even under `make -j`.
check:
	@$(MAKE) lint
	@$(MAKE) fmt-check
	@$(MAKE) bash5-check
	@$(MAKE) test-all
	@$(MAKE) source-audit

db-reset:
	@test -n "$(AUDL_DB_PATH)" || { echo "Error: AUDL_DB_PATH env var is required. Run: AUDL_DB_PATH=/path/to/library.sqlite make db-reset"; exit 1; }
	@test -f "$(AUDL_DB_PATH)" || { echo "Error: database not found: $(AUDL_DB_PATH)"; exit 1; }
	@printf "Resetting album_quality and scan_roadmap in: %s\n" "$(AUDL_DB_PATH)"
	@printf "This will clear all scan results for a full rescan. Continue? [y/N] " && read ans && [ "$${ans}" = "y" ]
	@sqlite3 "$(AUDL_DB_PATH)" "DELETE FROM album_quality; DELETE FROM scan_roadmap;" && \
		printf "Reset complete. album_quality and scan_roadmap are now empty.\n"
	@_db_slug=$$(printf '%s' "$(AUDL_DB_PATH)" | tr -cs 'A-Za-z0-9_-' '_'); \
		_cache="$${TMPDIR:-/tmp}/audlint_task_last_discovery_$${_db_slug}"; \
		rm -f "$$_cache" && printf "Discovery cache cleared: %s\n" "$$_cache" || true
