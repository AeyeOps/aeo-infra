.PHONY: validate test integration-test integration-test-windows build clean distclean

# Run all code quality checks
validate:
	uv run ruff format src/
	uv run ruff check --fix src/
	uv run ruff check src/
	uvx ty check src/

# Run local tests (excludes integration tests)
test: validate
	uv run pytest tests/ -v --ignore=tests/integration

# Run Docker Compose integration tests (Linux only)
integration-test:
	./tests/integration/run-tests.sh

# Run integration tests with Windows VM (requires golden image)
integration-test-windows:
	./tests/integration/run-tests.sh --with-windows

# Build standalone binary with PyInstaller and install to /usr/local/bin
# Uses persisted spec file if exists, otherwise generates new one
build: validate
	@if [ -f mesh.spec ]; then \
		echo "Using existing mesh.spec"; \
		uv run pyinstaller --noconfirm mesh.spec; \
	else \
		echo "Generating new mesh.spec"; \
		uv run pyinstaller \
			--onefile \
			--name mesh \
			--distpath dist/ \
			--workpath dist/build \
			--hidden-import mesh.commands.server \
			--hidden-import mesh.commands.client \
			--hidden-import mesh.commands.status \
			--hidden-import mesh.commands.peer \
			--hidden-import mesh.commands.wsl \
			--hidden-import mesh.commands.windows \
			--hidden-import mesh.commands.ubuntu \
			--hidden-import mesh.commands.remote \
			--hidden-import mesh.commands.init \
			--hidden-import mesh.commands.host \
			--hidden-import mesh.commands.harden \
			--hidden-import mesh.core.environment \
			--hidden-import mesh.core.config \
			--hidden-import mesh.core.syncthing \
			--hidden-import mesh.core.headscale \
			--hidden-import mesh.core.tailscale \
			--hidden-import mesh.core.privacy \
			--hidden-import mesh.core.templates \
			--hidden-import mesh.utils.output \
			--hidden-import mesh.utils.process \
			--hidden-import mesh.utils.ssh \
			--hidden-import mesh.discovery \
			src/mesh/__main__.py; \
	fi
	cp dist/mesh /usr/local/bin/mesh
	@echo "Installed: /usr/local/bin/mesh"

# Clean build artifacts (preserves mesh.spec for reproducible builds)
clean:
	rm -rf dist/ build/
	rm -rf src/mesh/__pycache__ src/mesh/**/__pycache__
	rm -rf .ruff_cache .ty_cache
	find . -type f -name "*.pyc" -delete
	find . -type d -name "__pycache__" -delete

# Deep clean including spec file
distclean: clean
	rm -f mesh.spec
