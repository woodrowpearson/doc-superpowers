"""doc-search: an opt-in MCP server over a repository's docs and code."""

from importlib.metadata import PackageNotFoundError, version

try:
    __version__ = version("doc-search")
except PackageNotFoundError:  # running from a source tree that was never installed
    __version__ = "0+unknown"

__all__ = ["__version__"]
