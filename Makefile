# mirroret Makefile
# Targets: lint, format, test, validate

SHELL := /bin/bash
# Production scripts (linted strictly).
# mirroret.sh and mirroret-unified.sh are legacy reference files - kept for
# comparison, not actively maintained, so excluded from strict lint.
SCRIPTS := install.sh uninstall.sh mirroretctl $(wildcard lib/*.sh) $(wildcard scripts/*.sh)
# The mirroring engines. Plain Python 3, standard library only - so the only
# lint they need is a syntax check under whatever python3 the host has.
ENGINES := $(wildcard engines/*.py) $(wildcard tests/fixtures/*.py)
TEST_DIR := tests

.PHONY: all lint format test test-integration test-all validate check-deps help dry-run clean uninstall

all: lint test

# -- Dependency check ----------------------------------------------------------

check-deps:
	@echo "Checking for required tools..."
	@missing=""; \
	for cmd in python3 shellcheck shfmt bash; do \
		if ! command -v $$cmd >/dev/null 2>&1; then \
			echo " MISSING: $$cmd"; \
			missing="$$missing $$cmd"; \
		else \
			echo " OK: $$cmd ($$( $$cmd --version 2>&1 | head -1 ))"; \
		fi; \
	done; \
	if command -v bats >/dev/null 2>&1; then \
		echo " OK: bats ($$(bats --version 2>/dev/null))"; \
	else \
		echo " MISSING: bats (optional, for tests)"; \
	fi; \
	if [ -n "$$missing" ]; then \
		echo ""; \
		echo "Install missing tools:"; \
		echo " Ubuntu/Debian: apt-get install shellcheck shfmt"; \
		echo " RHEL/Fedora: dnf install ShellCheck"; \
		echo " shfmt: go install mvdan.cc/sh/v3/cmd/shfmt@latest"; \
		echo " bats: npm install -g bats OR apt-get install bats"; \
	fi

# -- Linting -------------------------------------------------------------------

lint: lint-shellcheck lint-python

lint-shellcheck:
	@if ! command -v shellcheck >/dev/null 2>&1; then \
		echo "shellcheck not found. Install it: apt-get install shellcheck"; \
		exit 1; \
	fi
	@echo "Running shellcheck..."
	@failed=0; \
	for f in $(SCRIPTS); do \
		if [ -f "$$f" ]; then \
			echo " $$f"; \
			shellcheck --shell=bash --severity=warning --external-sources "$$f" || failed=1; \
		fi; \
	done; \
	if [ "$$failed" -eq 1 ]; then \
		echo "shellcheck found issues."; \
		exit 1; \
	else \
		echo "shellcheck: all OK"; \
	fi

lint-python:
	@if ! command -v python3 >/dev/null 2>&1; then \
		echo "python3 not found - the mirroring engines require it."; \
		exit 1; \
	fi
	@echo "Checking engine syntax with $$(python3 -V 2>&1)..."
	@failed=0; \
	for f in $(ENGINES); do \
		if python3 -c "import ast,sys; ast.parse(open(sys.argv[1]).read(), sys.argv[1])" "$$f"; then \
			echo " $$f"; \
		else \
			failed=1; \
		fi; \
	done; \
	if [ "$$failed" -eq 1 ]; then \
		echo "python syntax errors found."; \
		exit 1; \
	else \
		echo "python: all OK"; \
	fi
	@# The engines must run on the oldest interpreter our supported distros
	@# ship (RHEL 8 has python3.6), so reject 3.10+ only syntax.
	@echo "Checking engines import cleanly..."
	@PYTHONPATH=engines python3 -c "import mirroret_fetch, mirroret_apt, mirroret_rpm; print(' imports OK')"

lint-tests:
	@if ! command -v shellcheck >/dev/null 2>&1; then \
		echo "shellcheck not found. Skipping test linting."; \
		exit 0; \
	fi
	@echo "Running shellcheck on tests..."
	@shellcheck --shell=bash --severity=warning \
		$(TEST_DIR)/test_helpers.bash \
		$(wildcard $(TEST_DIR)/*.bats) 2>/dev/null || true

# -- Formatting ----------------------------------------------------------------

format:
	@if ! command -v shfmt >/dev/null 2>&1; then \
		echo "shfmt not found. Install: go install mvdan.cc/sh/v3/cmd/shfmt@latest"; \
		exit 1; \
	fi
	@echo "Running shfmt (in-place)..."
	@shfmt -w -i 4 -ln bash $(SCRIPTS)
	@echo "shfmt: formatting applied."

format-check:
	@if ! command -v shfmt >/dev/null 2>&1; then \
		echo "shfmt not found. Skipping format check."; \
		exit 0; \
	fi
	@echo "Checking formatting with shfmt..."
	@if shfmt -d -i 4 -ln bash $(SCRIPTS) | grep -q .; then \
		echo "Formatting issues found. Run: make format"; \
		exit 1; \
	else \
		echo "shfmt: all files properly formatted"; \
	fi

# -- Tests ---------------------------------------------------------------------

test:
	@if ! command -v bats >/dev/null 2>&1; then \
		echo "bats not found. Install it to run tests."; \
		echo " npm install -g bats OR apt-get install bats"; \
		exit 1; \
	fi
	@echo "Running all unit+integration tests..."
	@bats --tap $(TEST_DIR)/*.bats

test-integration:
	@if ! command -v bats >/dev/null 2>&1; then \
		echo "bats not found."; exit 1; \
	fi
	@echo "Running integration tests..."
	@bats --tap $(TEST_DIR)/test_integration.bats

test-all: test

# Just the engine + multi-distro target tests. These are the slow ones (they
# start real HTTP servers), so it helps to be able to run them alone.
test-engines:
	@if ! command -v bats >/dev/null 2>&1; then \
		echo "bats not found."; exit 1; \
	fi
	@bats --tap $(TEST_DIR)/test_engines.bats $(TEST_DIR)/test_targets.bats

test-verbose:
	@if ! command -v bats >/dev/null 2>&1; then \
		echo "bats not found."; exit 1; \
	fi
	@bats --show-output-of-passing-tests $(TEST_DIR)/*.bats

# -- Validation ----------------------------------------------------------------

validate:
	@if [ "$$(id -u)" -ne 0 ]; then \
		echo "Validation requires root: sudo make validate"; \
		exit 1; \
	fi
	@bash install.sh --check

# -- Dry run -------------------------------------------------------------------

dry-run:
	@bash install.sh --dry-run --non-interactive

# -- Uninstall preview --------------------------------------------------------

uninstall:
	@bash uninstall.sh --list

# -- Cleanup -------------------------------------------------------------------

clean:
	@echo "Removing temporary test artifacts..."
	@rm -f /tmp/mirroret.*
	@echo "Done."

# -- Help ---------------------------------------------------------------------

help:
	@echo ""
	@echo "mirroret Makefile targets:"
	@echo ""
	@echo " make lint Run shellcheck on scripts + syntax-check the engines"
	@echo " make lint-python Syntax-check engines/*.py only"
	@echo " make format Auto-format scripts with shfmt (in-place)"
	@echo " make format-check Check formatting without modifying files"
	@echo " make test Run every BATS test (no root needed)"
	@echo " make test-integration Run integration tests subset"
	@echo " make test-engines Run the APT/RPM engine + target tests only"
	@echo " make test-all Alias for 'make test'"
	@echo " make test-verbose Run all tests with verbose output"
	@echo " make validate Validate existing installation (requires root)"
	@echo " make dry-run Preview what install.sh would do"
	@echo " make uninstall Preview uninstall plan (sudo ./uninstall.sh for the real thing)"
	@echo " make check-deps Check for required tools"
	@echo " make clean Remove temp files"
	@echo " make help Show this help"
	@echo ""
	@echo "Required tools: python3 (engines), shellcheck, shfmt, bats"
	@echo " Ubuntu: apt-get install shellcheck bats"
	@echo " shfmt: go install mvdan.cc/sh/v3/cmd/shfmt@latest"
	@echo ""
