REPORTS_DIR ?= reports
# Commands use `uv run` so pytest/pyyaml/ruff come from the project env (run `uv sync` first).

.PHONY: test lint format test-vmaas

test:
	mkdir -p $(REPORTS_DIR)
	uv run pytest tests/ -v $(if $(TEST),-k "$(TEST)") --junitxml=$(REPORTS_DIR)/results.xml

lint:
	uv run ruff check tests/
	uv run ruff format --check tests/

format:
	uv run ruff format tests/

test-vmaas:
	mkdir -p $(REPORTS_DIR)
	uv run pytest tests/vmaas/ -v $(if $(TEST),-k "$(TEST)") --junitxml=$(REPORTS_DIR)/vmaas.xml
