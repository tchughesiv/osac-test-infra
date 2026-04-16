REPORTS_DIR ?= reports

.PHONY: test lint format

test:
	mkdir -p $(REPORTS_DIR)
	pytest tests/ -v $(if $(TEST),-k "$(TEST)") --junitxml=$(REPORTS_DIR)/results.xml

lint:
	ruff check tests/
	ruff format --check tests/

format:
	ruff format tests/
