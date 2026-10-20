"""Repository helpers: discovery, worktrees, path confinement and the argv-only git wrappers."""

from __future__ import annotations

import shutil
from pathlib import Path

import pytest

from doc_search.repo import (
    GitError,
    NotARepo,
    RepoInfo,
    confine,
    diff_names,
    git,
    is_ancestor,
    ls_files,
    norm_rel,
    resolve_worktree,
    rev_parse,
    worktrees,
)


def test_from_cwd_in_worktree(git_repo) -> None:
    repo = git_repo()
    repo.write("a.txt", "a\n")
    repo.commit("base")
    linked = repo.add_worktree("one", "feat")

    main = RepoInfo.from_cwd(repo.root)
    other = RepoInfo.from_cwd(linked)

    assert main.top == repo.root
    assert other.top == linked
    assert main.common_dir == other.common_dir == (repo.root / ".git").resolve()


def test_from_cwd_in_subdirectory(git_repo) -> None:
    repo = git_repo()
    repo.write("docs/deep/a.md", "# A\n")
    repo.commit("base")
    info = RepoInfo.from_cwd(repo.root / "docs" / "deep")
    assert info.top == repo.root
    assert info.common_dir == (repo.root / ".git").resolve()


def test_from_cwd_outside_a_repository(tmp_path: Path, monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setenv("GIT_CEILING_DIRECTORIES", str(tmp_path.parent))
    plain = tmp_path / "plain"
    plain.mkdir()
    with pytest.raises(NotARepo):
        RepoInfo.from_cwd(plain)
    with pytest.raises(NotARepo):
        RepoInfo.from_cwd(tmp_path / "does-not-exist")


def test_worktrees_lists_real_paths(git_repo, tmp_path: Path) -> None:
    repo = git_repo()
    repo.write("a.txt", "a\n")
    repo.commit("base")
    linked = repo.add_worktree("one", "feat")
    info = RepoInfo.from_cwd(repo.root)
    assert worktrees(info) == [repo.root, linked]
    # the same answer from inside the linked worktree
    assert worktrees(RepoInfo.from_cwd(linked)) == [repo.root, linked]


def test_worktrees_skips_a_deleted_worktree(git_repo) -> None:
    repo = git_repo()
    repo.write("a.txt", "a\n")
    repo.commit("base")
    kept = repo.add_worktree("kept", "kept")
    deleted = repo.add_worktree("deleted", "deleted")
    shutil.rmtree(deleted)  # git still lists it, as prunable
    info = RepoInfo.from_cwd(repo.root)
    assert worktrees(info) == [repo.root, kept]
    with pytest.raises(ValueError, match="not a worktree of this repository"):
        resolve_worktree(info, str(deleted))


def test_git_helpers_ignore_discovery_overrides(git_repo, monkeypatch: pytest.MonkeyPatch, tmp_path: Path) -> None:
    """A server started from inside a git hook inherits GIT_DIR and friends; they must not redirect git."""
    repo = git_repo()
    repo.write("docs/a.md", "# A\n")
    repo.commit("base")
    monkeypatch.setenv("GIT_DIR", str(tmp_path / "elsewhere"))
    monkeypatch.setenv("GIT_WORK_TREE", str(tmp_path / "elsewhere"))
    monkeypatch.setenv("GIT_INDEX_FILE", str(tmp_path / "elsewhere-index"))
    info = RepoInfo.from_cwd(repo.root)
    assert info.top == repo.root
    assert ls_files(repo.root) == {"docs/a.md"}


def test_resolve_worktree(git_repo, tmp_path: Path) -> None:
    repo = git_repo()
    repo.write("a.txt", "a\n")
    repo.commit("base")
    linked = repo.add_worktree("one", "feat")
    info = RepoInfo.from_cwd(repo.root)

    assert resolve_worktree(info, None) == repo.root
    # an empty string is how some clients spell "not given"
    assert resolve_worktree(info, "") == repo.root
    assert resolve_worktree(info, str(linked)) == linked
    # a symlinked spelling of a worktree is still that worktree
    alias = tmp_path / "alias"
    alias.symlink_to(linked)
    assert resolve_worktree(info, str(alias)) == linked
    # a relative path is read against the launch top
    assert resolve_worktree(info, "../" + linked.name) == linked


def test_resolve_worktree_rejects_foreign_path(git_repo, tmp_path: Path) -> None:
    repo = git_repo()
    repo.write("a.txt", "a\n")
    repo.commit("base")
    repo.add_worktree("one", "feat")
    stranger = git_repo("stranger")
    stranger.write("b.txt", "b\n")
    stranger.commit("other repository")
    info = RepoInfo.from_cwd(repo.root)

    for requested in (str(stranger.root), str(tmp_path), "/etc", str(repo.root / "sub"), "sub"):
        with pytest.raises(ValueError, match="not a worktree of this repository"):
            resolve_worktree(info, requested)


@pytest.mark.parametrize(
    "rel",
    [
        "/etc/passwd",
        "../x",
        "docs/../../x",
        "docs/../a.md",
        ".git/config",
        "docs/.git/config",
        ".GIT/config",
        "link/secret.txt",
        "link",
        "gitlink/config",
        "",
        "a\0b",
    ],
)
def test_confine_rejects(git_repo, tmp_path: Path, rel: str) -> None:
    repo = git_repo()
    repo.write("docs/a.md", "# A\n")
    outside = tmp_path / "outside"
    outside.mkdir()
    (outside / "secret.txt").write_text("secret\n")
    (repo.root / "link").symlink_to(outside)
    # a symlink that stays inside the worktree but lands in .git is refused too
    (repo.root / "gitlink").symlink_to(repo.root / ".git")
    with pytest.raises(ValueError):
        confine(repo.root, rel)


def test_confine_accepts_paths_inside(git_repo) -> None:
    repo = git_repo()
    repo.write("docs/a.md", "# A\n")
    (repo.root / "docs" / "alias.md").symlink_to("a.md")
    assert confine(repo.root, "docs/a.md") == repo.root / "docs" / "a.md"
    assert confine(repo.root, "./docs/a.md") == repo.root / "docs" / "a.md"
    # an in-tree symlink resolves to its target, still inside
    assert confine(repo.root, "docs/alias.md") == repo.root / "docs" / "a.md"
    # a path that does not exist yet is the caller's "not found", not an escape
    assert confine(repo.root, "docs/missing.md") == repo.root / "docs" / "missing.md"
    # .github is not .git
    assert confine(repo.root, ".github/x.yml") == repo.root / ".github" / "x.yml"


def test_norm_rel() -> None:
    assert norm_rel("./docs/a.md") == "docs/a.md"
    assert norm_rel("././docs/a.md") == "docs/a.md"
    assert norm_rel("docs/a.md") == "docs/a.md"
    assert norm_rel(".github/x") == ".github/x"


def test_git_never_uses_a_shell(git_repo) -> None:
    repo = git_repo()
    repo.write("a.txt", "a\n")
    repo.commit("base")
    with pytest.raises(GitError):
        git(repo.root, "rev-parse", "--verify", "main; touch pwned")
    assert not (repo.root / "pwned").exists()
    assert git(repo.root, "rev-parse", "--abbrev-ref", "HEAD").strip() == "main"


def test_git_error_names_the_command(git_repo) -> None:
    repo = git_repo()
    with pytest.raises(GitError, match="rev-parse"):
        git(repo.root, "rev-parse", "--verify", "nope")


def test_ls_files_is_cached_plus_untracked_minus_ignored(git_repo) -> None:
    repo = git_repo()
    repo.write(".gitignore", "docs/tmp.md\n")
    repo.write("docs/a.md", "# A\n")
    repo.commit("base")
    repo.write("docs/new.md", "# New\n")
    repo.write("docs/tmp.md", "# Ignored\n")
    repo.write("docs/odd name é.md", "# Odd\n")
    assert ls_files(repo.root) == {".gitignore", "docs/a.md", "docs/new.md", "docs/odd name é.md"}


def test_rev_parse(git_repo) -> None:
    repo = git_repo()
    repo.write("a.txt", "a\n")
    head = repo.commit("base")
    assert rev_parse(repo.root, "main") == head
    assert rev_parse(repo.root, head) == head
    assert rev_parse(repo.root, head[:10]) == head
    assert rev_parse(repo.root, "nope") is None
    assert rev_parse(repo.root, "0" * 40) is None
    assert rev_parse(repo.root, "--all") is None
    assert rev_parse(repo.root, "") is None


def test_is_ancestor(git_repo) -> None:
    repo = git_repo()
    repo.write("a.txt", "a\n")
    first = repo.commit("first")
    repo.write("a.txt", "b\n")
    second = repo.commit("second")
    assert is_ancestor(repo.root, first, second)
    assert not is_ancestor(repo.root, second, first)
    assert not is_ancestor(repo.root, "0" * 40, second)
    assert not is_ancestor(repo.root, "--help", second)


def test_diff_names_non_ancestor(git_repo) -> None:
    """The stamp sits on a sibling branch: the diff is still the working tree against it."""
    repo = git_repo()
    repo.write("a.md", "a\n")
    repo.write("b.md", "b\n")
    repo.write("c.md", "c\n")
    repo.commit("base")
    repo.git("checkout", "-q", "-b", "sibling")
    repo.write("a.md", "a on sibling\n")
    stamp = repo.commit("sibling work")
    repo.git("checkout", "-q", "main")
    repo.write("b.md", "b on main\n")
    repo.commit("main work")
    repo.write("c.md", "c edited, not committed\n")

    assert not is_ancestor(repo.root, stamp, "HEAD")
    assert diff_names(repo.root, stamp) == {"a.md", "b.md", "c.md"}


def test_diff_names_lists_both_sides_of_a_rename(git_repo) -> None:
    repo = git_repo()
    repo.write("docs/old.md", "# Same content, long enough to be detected as a rename\n" * 5)
    stamp = repo.commit("base")
    repo.git("mv", "docs/old.md", "docs/new.md")
    assert diff_names(repo.root, stamp) == {"docs/old.md", "docs/new.md"}


def test_diff_names_missing_commit_is_none(git_repo) -> None:
    repo = git_repo()
    repo.write("a.md", "a\n")
    repo.commit("base")
    assert diff_names(repo.root, "0123456789abcdef0123456789abcdef01234567") is None
    assert diff_names(repo.root, "no-such-ref") is None
    assert diff_names(repo.root, "--output=pwned") is None
    assert not (repo.root / "pwned").exists()
