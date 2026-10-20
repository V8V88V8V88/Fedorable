.PHONY: test lint check

SHELLCHECK ?= shellcheck

test:
	python3 -m unittest discover -s tests -v

lint:
	$(SHELLCHECK) -x -P . fedorable.sh
	$(SHELLCHECK) install.sh
	cat lib/ui.sh lib/tasks.sh lib/cli.sh | $(SHELLCHECK) -x --shell=bash -

check: lint test
