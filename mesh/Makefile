.PHONY: validate build clean distclean

# Run all code quality checks
validate:
	uv run ruff format src/
	uv run ruff check --fix src/
	uv run ruff check src/
	uvx ty check src/

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
			--hidden-import mesh.core.environment \
			--hidden-import mesh.core.config \
			--hidden-import mesh.core.syncthing \
			--hidden-import mesh.core.headscale \
			--hidden-import mesh.core.tailscale \
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
