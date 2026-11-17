# reviewer.nvim Makefile
# Branch-scoped review comments for codediff.nvim

.PHONY: test test-file lint format check help

# Default target
.DEFAULT_GOAL := help

# Run the test suite in a throwaway data dir
test:
	@TMP=$$(mktemp -d); \
	XDG_DATA_HOME=$$TMP/data nvim --headless -u NONE --noplugin -l tests/test_reviewer.lua; \
	status=$$?; rm -rf $$TMP; exit $$status

# Run one test file (usage: make test-file FILE=tests/test_reviewer.lua)
test-file:
	@if [ -z "$(FILE)" ]; then \
		echo "Usage: make test-file FILE=tests/test_reviewer.lua"; \
		exit 1; \
	fi
	@TMP=$$(mktemp -d); \
	XDG_DATA_HOME=$$TMP/data nvim --headless -u NONE --noplugin -l $(FILE); \
	status=$$?; rm -rf $$TMP; exit $$status

# Lint Lua code with luacheck
lint:
	@luacheck lua/ plugin/ tests/

# Format Lua code with stylua
format:
	@stylua lua/ plugin/ tests/

# Run all checks (format, lint, test)
check: format lint test

# Display help
help:
	@echo "reviewer.nvim - Available targets:"
	@echo ""
	@echo "  make test              Run the test suite"
	@echo "  make test-file FILE=   Run a specific test file"
	@echo "  make lint              Run luacheck linter"
	@echo "  make format            Format code with stylua"
	@echo "  make check             Run format, lint, and test"
	@echo "  make help              Show this help message"
	@echo ""
	@echo "Examples:"
	@echo "  make test-file FILE=tests/test_reviewer.lua"
	@echo "  make check"
