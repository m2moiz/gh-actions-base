"""A placeholder so the template's own CI has something real to run.

Delete this package when you start a project from the template. It exists so
the workflows are exercised end to end here rather than only being validated
as YAML -- a pipeline that has never executed is not a pipeline that works.
"""

__all__ = ["add"]


def add(a: int, b: int) -> int:
    """Add two integers."""
    return a + b
