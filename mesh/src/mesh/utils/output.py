"""Rich console output helpers."""

from rich.console import Console
from rich.panel import Panel
from rich.table import Table

console = Console()


def info(msg: str) -> None:
    """Print an info message."""
    console.print(f"[blue]INFO:[/blue] {msg}")


def ok(msg: str) -> None:
    """Print a success message."""
    console.print(f"[green]OK:[/green] {msg}")


def warn(msg: str) -> None:
    """Print a warning message."""
    console.print(f"[yellow]WARN:[/yellow] {msg}")


def error(msg: str) -> None:
    """Print an error message."""
    console.print(f"[red]ERROR:[/red] {msg}")


def section(title: str) -> None:
    """Print a section header."""
    console.print(f"\n[bold]=== {title} ===[/bold]")


def panel(content: str, title: str | None = None) -> None:
    """Print content in a panel."""
    console.print(Panel(content, title=title))


def create_table(title: str, columns: list[str]) -> Table:
    """Create a table with the given columns."""
    table = Table(title=title)
    for col in columns:
        table.add_column(col)
    return table


def print_table(table: Table) -> None:
    """Print a table."""
    console.print(table)
