.PHONY: install build test test-py test-web run examples

install:
	pip install -e ".[dev]"
	cd frontend && npm install

build:
	cd frontend && npm run build

test: test-py test-web

test-py:
	python -m pytest

test-web:
	cd frontend && npm test && npx tsc -b

run:
	python -m backend --host 0.0.0.0 --port 8000

examples:
	python scripts/make_examples.py
