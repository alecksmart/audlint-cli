SHELL := /opt/homebrew/bin/bash

PYTHON_BIN ?= python3
PREFIX ?= $(HOME)/bin
INSTALLABLE_SCRIPTS := $(sort $(notdir $(wildcard bin/*.sh)))
SHELLCHECK_TARGETS ?= bin lib/sh test/sh
SHFMT_TARGETS ?= test/sh
SHFMT_EXTRA ?= install.sh
SHELLCHECK_OPTS ?= -e SC2004,SC2015,SC2029,SC2034,SC2162,SC2178,SC2181,SC2221,SC2222,SC2235

.PHONY: help install uninstall relink install-env lint fmt-check bash5-check test test-core test-legacy check

help:
	@printf "%s\n" \
		"Targets:" \
		"  install      Symlink bin/*.sh scripts into PREFIX ($(PREFIX))" \
		"  uninstall    Remove bin/*.sh symlinks from PREFIX ($(PREFIX))" \
		"  relink       Recreate bin/*.sh symlinks in PREFIX" \
		"  install-env  Generate .env via install.sh" \
		"  lint         Run shellcheck on shell scripts" \
		"  fmt-check    Run shfmt -d on shell scripts" \
		"  bash5-check  Validate Bash 5 shebang/parse consistency" \
		"  test-core    Run baseline Python unit tests in test/" \
		"  test-legacy  Run migrated legacy test suite in test/legacy" \
		"  test         Run test-core + test-legacy" \
		"  check        Run lint + fmt-check + bash5-check + test"

install:
	@mkdir -p "$(PREFIX)"
	@for script in $(INSTALLABLE_SCRIPTS); do \
		ln -sfn "$(abspath bin)/$$script" "$(PREFIX)/$$script"; \
	done

uninstall:
	@for script in $(INSTALLABLE_SCRIPTS); do \
		rm -f "$(PREFIX)/$$script"; \
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

test-core:
	@$(PYTHON_BIN) -m unittest discover -s test -p 'test_*.py'

test-legacy:
	@$(PYTHON_BIN) -m unittest discover -s test/legacy -p 'test_*.py'

test: test-core test-legacy

check: lint fmt-check bash5-check test
