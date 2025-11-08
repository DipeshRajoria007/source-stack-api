.PHONY: dev lint test build run worker redis

dev:
	@if [ ! -d "venv" ]; then \
		echo "Creating virtual environment..."; \
		python3 -m venv venv; \
		echo "Installing dependencies..."; \
		venv/bin/pip install --upgrade pip && venv/bin/pip install -r requirements.txt; \
	fi
	venv/bin/uvicorn app.main:app --reload --host 0.0.0.0 --port 8000

worker:
	@if [ ! -d "venv" ]; then \
		echo "Creating virtual environment..."; \
		python3 -m venv venv; \
		echo "Installing dependencies..."; \
		venv/bin/pip install --upgrade pip && venv/bin/pip install -r requirements.txt; \
	fi
	venv/bin/celery -A app.celery_app worker --loglevel=info

redis:
	docker run -d --name redis-sourcestack -p 6379:6379 redis:7-alpine

lint:
	@echo "Linting (install ruff/flake8 for actual linting)"
	@python -m py_compile app/*.py || true

test:
	pytest tests/ -v

build:
	docker build -t sourcestack-api .

run:
	docker run -p 8000:8000 --env-file .env sourcestack-api

