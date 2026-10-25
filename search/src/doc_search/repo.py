"""Repository helpers: finding the repository, its worktrees, confined paths, and argv-only git.

Every git call here is an argv list run without a shell, with the discovery overrides
(`GIT_DIR`, `GIT_WORK_TREE`, ...) removed so the call acts on the directory it was given,
and without optional index locks so a read never contends with the user's own git.
"""

from __future__ import annotations

import os
import subprocess
from dataclasses import dataclass
from pathlib import Path
from typing import NamedTuple

GIT_TIMEOUT_SECONDS = 120

# Variables that make git look somewhere other than the directory it runs in.
_DISCOVERY_VARS = frozenset({"GIT_DIR", "GIT_WORK_TREE", "GIT_INDEX_FILE", "GIT_COMMON_DIR"})


class GitError(RuntimeError):
    """A git command failed, timed out or could not be started."""


class NotARepo(Exception):
    """The directory is not inside a git work tree."""


class _Done(NamedTuple):
    rc: int
    out: str
    err: str


def _exec(top: Path, args: tuple[str, ...]) -> subprocess.CompletedProcess[bytes]:
    env = {key: value for key, value in os.environ.items() if key not in _DISCOVERY_VARS}
    env["GIT_OPTIONAL_LOCKS"] = "0"
    env["GIT_TERMINAL_PROMPT"] = "0"
    try:
        return subprocess.run(
            ["git", *args],
            cwd=top,
            env=env,
            stdin=subprocess.DEVNULL,
            capture_output=True,
            timeout=GIT_TIMEOUT_SECONDS,
            check=False,
        )
    except subprocess.TimeoutExpired as err:
        raise GitError(f"git {' '.join(args)} timed out after {GIT_TIMEOUT_SECONDS}s") from err
    except OSError as err:  # no git binary, or no such directory
        raise GitError(f"cannot run git in {top}: {err}") from err


def _run(top: Path, args: tuple[str, ...]) -> _Done:
    done = _exec(top, args)
    return _Done(done.returncode, done.stdout.decode("utf-8", "replace"), done.stderr.decode("utf-8", "replace"))


def git(top: Path, *args: str) -> str:
    """Run `git <args>` in `top` and return stdout. Raises GitError on a non-zero exit."""
    done = _run(Path(top), args)
    if done.rc != 0:
        raise GitError(f"git {' '.join(args)} failed ({done.rc}): {done.err.strip()}")
    return done.out


def git_bytes(top: Path, *args: str) -> bytes:
    """Run `git <args>` in `top` and return stdout undecoded (a blob's bytes). Raises GitError on a non-zero exit."""
    done = _exec(Path(top), args)
    if done.returncode != 0:
        raise GitError(
            f"git {' '.join(args)} failed ({done.returncode}): {done.stderr.decode('utf-8', 'replace').strip()}"
        )
    return done.stdout


def norm_rel(path: str) -> str:
    """A repo-relative path without leading `./` segments."""
    while path.startswith("./"):
        path = path[2:]
    return path


@dataclass(frozen=True)
class RepoInfo:
    """Where a repository is: the launch worktree's top and the git dir every worktree shares."""

    top: Path
    common_dir: Path

    @classmethod
    def from_cwd(cls, cwd: Path) -> RepoInfo:
        cwd = Path(cwd)
        try:
            out = git(cwd, "rev-parse", "--show-toplevel", "--git-common-dir")
        except GitError as err:
            raise NotARepo(f"not inside a git work tree: {cwd}") from err
        lines = out.splitlines()
        if len(lines) != 2:
            raise NotARepo(f"not inside a git work tree: {cwd}")
        common = Path(lines[1])
        if not common.is_absolute():  # relative to the directory git ran in
            common = cwd / common
        return cls(top=Path(lines[0]).resolve(), common_dir=common.resolve())


def worktrees(repo: RepoInfo) -> list[Path]:
    """The real paths of the repository's worktrees, the main one first.

    Bare entries and worktrees whose directory has been deleted (prunable) are left out:
    there is nothing to search in them.
    """
    found: list[Path] = []
    for block in git(repo.top, "worktree", "list", "--porcelain").split("\n\n"):
        lines = block.strip().splitlines()
        if not lines or not lines[0].startswith("worktree "):
            continue
        if any(line == "bare" or line.startswith("prunable") for line in lines[1:]):
            continue
        path = Path(lines[0][len("worktree ") :]).resolve()
        if path not in found:
            found.append(path)
    return found


def resolve_worktree(repo: RepoInfo, requested: str | None, default: Path | None = None) -> Path:
    """The worktree a request names. `None` (or an empty string) is `default`, else the launch top.

    A relative path is read against the launch top. A path that is not exactly one of the
    repository's worktrees is refused, so a tool argument cannot point at another directory.
    """
    if requested is None or not requested.strip():
        return default if default is not None else repo.top
    path = Path(requested)
    if not path.is_absolute():
        path = repo.top / path
    try:
        real = path.resolve()
    except (OSError, RuntimeError) as err:
        raise ValueError(f"not a worktree of this repository: {requested}") from err
    if real not in worktrees(repo):
        raise ValueError(f"not a worktree of this repository: {requested}")
    return real


def client_worktree(repo: RepoInfo, path: str | None) -> Path | None:
    """The worktree of this repository that holds `path` (an MCP client's working directory), or None.

    None for an empty path, a directory git cannot read, another repository, or a worktree that
    `git worktree list` does not list: the caller then keeps the launch top.
    """
    if path is None or not path.strip():
        return None
    try:
        found = RepoInfo.from_cwd(Path(path))
    except (NotARepo, OSError):
        return None
    if found.common_dir != repo.common_dir:
        return None
    try:
        return found.top if found.top in worktrees(repo) else None
    except GitError:
        return None


def _has_dot_git(parts: tuple[str, ...] | list[str]) -> bool:
    # case-insensitive: on the default macOS filesystem `.GIT` is `.git`
    return any(part.lower() == ".git" for part in parts)


def confine(top: Path, rel: str) -> Path:
    """The real path of `rel` under `top`, or ValueError when it is not safely inside.

    Refused: an empty or NUL-bearing path, an absolute path, any `..` component, any
    `.git` component (also after symlinks are resolved), and a path whose resolution
    leaves `top`. A path that does not exist yet is fine: that is the caller's "not found".
    """
    if not rel or "\0" in rel:
        raise ValueError(f"invalid path: {rel!r}")
    if os.path.isabs(rel):
        raise ValueError(f"absolute paths are not allowed: {rel}")
    parts = rel.split("/")
    if ".." in parts:
        raise ValueError(f"path escapes the worktree: {rel}")
    if _has_dot_git(parts):
        raise ValueError(f"path is inside .git: {rel}")
    try:
        real_top = Path(top).resolve()
        real = (real_top / rel).resolve()
    except (OSError, RuntimeError) as err:  # e.g. a symlink loop
        raise ValueError(f"cannot resolve path: {rel}") from err
    try:
        inner = real.relative_to(real_top)
    except ValueError:
        raise ValueError(f"path leaves the worktree: {rel}") from None
    if _has_dot_git(inner.parts):
        raise ValueError(f"path resolves into .git: {rel}")
    return real


def rev_parse(top: Path, ref: str) -> str | None:
    """The full sha of the commit `ref` names, or None when there is no such commit locally."""
    if not ref or ref.startswith("-") or "\0" in ref:
        return None
    done = _run(Path(top), ("rev-parse", "--verify", "--quiet", f"{ref}^{{commit}}"))
    sha = done.out.strip()
    return sha if done.rc == 0 and sha else None


def is_ancestor(top: Path, a: str, b: str) -> bool:
    """True when commit `a` is an ancestor of (or equal to) `b`. A missing commit is False."""
    if a.startswith("-") or b.startswith("-"):
        return False
    return _run(Path(top), ("merge-base", "--is-ancestor", a, b)).rc == 0


def is_ignored(top: Path, rel: str) -> bool:
    """True when git ignores the repo-relative path `rel` in `top`: untracked and matched by an ignore rule.

    A tracked file is never ignored (whatever the rules say), nor is an untracked one no rule matches.
    The path is literal. Tracked means ls-files prints exactly `rel` for a `:(literal)` pathspec: plain
    check-ignore matches the path against the index as a glob, so `?.secret` would pass as a tracked
    `x.secret`. The rules are then asked with `--no-index`, where the `./` keeps a leading `:` from
    being read as pathspec magic (check-ignore refuses `--literal-pathspecs`). Raises GitError when git
    cannot answer.
    """
    tracked = _run(Path(top), ("ls-files", "--cached", "-z", "--", f":(literal){rel}"))
    if tracked.rc != 0:
        raise GitError(f"git ls-files {rel} failed ({tracked.rc}): {tracked.err.strip()}")
    if rel in tracked.out.split("\0"):
        return False
    done = _run(Path(top), ("check-ignore", "--no-index", "-q", "--", f"./{rel}"))
    if done.rc in (0, 1):  # 0: ignored, 1: not ignored
        return done.rc == 0
    raise GitError(f"git check-ignore {rel} failed ({done.rc}): {done.err.strip()}")


def ls_files(top: Path) -> set[str]:
    """Tracked and untracked-but-not-ignored paths, relative to `top`."""
    out = git(top, "ls-files", "--cached", "--others", "--exclude-standard", "-z")
    return {path for path in out.split("\0") if path}


def diff_names(top: Path, commit: str) -> set[str] | None:
    """Paths that differ between the working tree and `commit` (a rename lists both names).

    Needs no ancestry: `commit` may sit on a sibling branch. None when the commit is not
    present locally.
    """
    sha = rev_parse(top, commit)
    if sha is None:
        return None
    out = git(top, "diff", "--name-only", "--no-renames", "-z", sha, "--")
    return {path for path in out.split("\0") if path}
