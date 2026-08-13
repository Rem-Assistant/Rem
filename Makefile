.PHONY: setup submodules bootstrap-submodules update-submodules xcodebuild-safe lint test test-all observability
.PHONY: symphony symphony_start symphony_stop symphony_status symphony_preflight symphony_dispatch symphony_clean symphony_logs
.PHONY: symphony\:start symphony\:stop symphony\:status symphony\:preflight symphony\:dispatch symphony\:clean symphony\:logs
.PHONY: check-readmes

setup: submodules

submodules:
	./scripts/setup.sh

bootstrap-submodules:
	./scripts/bootstrap-submodules.sh

update-submodules:
	git submodule update --remote --recursive

xcodebuild-safe:
	./scripts/xcodebuild-with-submodules.sh $(ARGS)

lint:
	@which swiftlint >/dev/null 2>&1 || { echo "SwiftLint not installed. Run: brew install swiftlint"; exit 1; }
	swiftlint --config .swiftlint.yml --no-cache

test:
	./scripts/test-harness.sh --ios

test-all:
	./scripts/test-harness.sh --all

observability:
	@./scripts/observability.sh help

# ── README enforcement ───────────────────────────────────────────────────────────
#
# Two checks:
#   check-readmes        — existence only (fast, always run)
#   check-readmes-diff  — diff-aware (code changed? README updated?) (CI/commit phase)
#
# Pre-commit hook install:
#   cp scripts/pre-commit.sh .git/hooks/pre-commit && chmod +x .git/hooks/pre-commit

SOURCE_DIRS = RemClaw/Sources RemClawMac/Sources Shared/Gateway Shared/Models Shared/Protocols Shared/Services Shared/Views backend/src scripts

check-readmes:
	@found=0; \
	for dir in $(SOURCE_DIRS); do \
		if [ ! -f "$$dir/README.md" ]; then \
			echo "MISSING: $$dir/README.md"; \
			found=$$((found+1)); \
		fi; \
	done; \
	if [ $$found -gt 0 ]; then \
		echo ""; echo "$$found folder(s) missing README.md. Create one."; \
		exit 1; \
	else \
		echo "All source folders have README.md (existence check)"; \
	fi

# Diff-aware check: also verifies that touched folders' READMEs were updated
# Run as part of CI or pre-commit
check-readmes-diff:
	./scripts/check-dirty-readmes.sh --staged

# ── Symphony Daemon ───────────────────────────────────────────────────────────
#
# Autonomous agent orchestrator. Polls GitHub Projects/issues for dispatch-ready work,
# spawns Codex agents in per-issue workspaces, and auto-retries on failure.
#
# State: symphony-state.json (runtime artifact, ignored)
# Logs:  symphony-daemon.log

SYMPHONY_ROOT ?= $(CURDIR)/.symphony-workspaces
SYMPHONY_POLL_MS ?= 30000
SYMPHONY_MAX ?= 3
SYMPHONY_MAX_RETRIES ?= 3

symphony:
	$(MAKE) symphony_status

symphony_start:
	SYMPHONY_ROOT=$(SYMPHONY_ROOT) SYMPHONY_POLL_MS=$(SYMPHONY_POLL_MS) SYMPHONY_MAX=$(SYMPHONY_MAX) \
	SYMPHONY_MAX_RETRIES=$(SYMPHONY_MAX_RETRIES) \
	/opt/homebrew/bin/node scripts/symphony-daemon.js start

symphony_stop:
	SYMPHONY_ROOT=$(SYMPHONY_ROOT) /opt/homebrew/bin/node scripts/symphony-daemon.js stop

symphony_status:
	SYMPHONY_ROOT=$(SYMPHONY_ROOT) /opt/homebrew/bin/node scripts/symphony-daemon.js status

symphony_preflight:
	SYMPHONY_ROOT=$(SYMPHONY_ROOT) /opt/homebrew/bin/node scripts/symphony-daemon.js preflight

symphony_dispatch:
	SYMPHONY_ROOT=$(SYMPHONY_ROOT) /opt/homebrew/bin/node scripts/symphony-daemon.js dispatch

symphony_clean:
	SYMPHONY_ROOT=$(SYMPHONY_ROOT) /opt/homebrew/bin/node scripts/symphony-daemon.js clean

symphony_logs:
	@if [ -f symphony-daemon.log ]; then \
		tail -50 symphony-daemon.log; \
	else \
		echo "No daemon log found. Run 'make symphony_start' first."; \
	fi

symphony\:start: symphony_start
symphony\:stop: symphony_stop
symphony\:status: symphony_status
symphony\:preflight: symphony_preflight
symphony\:dispatch: symphony_dispatch
symphony\:clean: symphony_clean
symphony\:logs: symphony_logs
