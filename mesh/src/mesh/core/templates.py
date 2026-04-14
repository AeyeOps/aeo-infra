"""Template file loader for privacy-hardening templates."""

from importlib import resources
from pathlib import Path


def get_template(name: str) -> str:
    """Load a template file by name and return its contents."""
    ref = resources.files("mesh.templates").joinpath(name)
    return ref.read_text(encoding="utf-8")


def get_template_path(name: str) -> Path:
    """Get the filesystem path to a template file."""
    ref = resources.files("mesh.templates").joinpath(name)
    # resources.as_file() provides a context manager, but for read-only
    # templates that are part of the installed package, the path is stable
    return Path(str(ref))


def list_templates() -> list[str]:
    """List all available template files (excluding __init__.py)."""
    templates_dir = resources.files("mesh.templates")
    return sorted(
        item.name
        for item in templates_dir.iterdir()
        if not item.name.startswith("__")
    )
