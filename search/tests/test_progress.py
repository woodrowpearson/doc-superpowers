"""Build progress: the windowed rate, the ETA, the per-arch first-build estimate, the status line copy,
and the per-worktree file that other processes (`doc-search status`) read."""

from __future__ import annotations

import json
import logging
import os
import platform
import re
import subprocess
import sys
import threading
from pathlib import Path

import pytest

from doc_search import progress
from doc_search.encode_cache import cache_root
from doc_search.progress import (
    ARCH_RATES,
    RATE_WINDOW_S,
    BuildProgress,
    ProgressView,
    arch_rate,
    fmt_duration,
    progress_path,
    read_progress,
)


class Clock:
    """A settable clock: tests move time by assigning `t`."""

    def __init__(self, t: float = 1000.0) -> None:
        self.t = t

    def __call__(self) -> float:
        return self.t


def view(**fields: object) -> ProgressView:
    base = dict(
        phase="encoding",
        total=194_564,
        done=12_345,
        from_cache=0,
        rate=None,
        eta_s=None,
        estimate_s=None,
        holder_pid=None,
        pid=4242,
    )
    return ProgressView(**{**base, **fields})  # type: ignore[arg-type]


@pytest.fixture
def worktree(tmp_path: Path) -> Path:
    path = tmp_path / "worktree"
    path.mkdir()
    return path


# -- fmt_duration -----------------------------------------------------------------------------


@pytest.mark.parametrize(
    ("seconds", "text"),
    [
        (0, "0 s"),
        (-5, "0 s"),
        (0.9, "0 s"),
        (55, "55 s"),
        (59.9, "59 s"),
        (60, "1 min"),
        (119.9, "1 min"),
        (240, "4 min"),
        (59 * 60, "59 min"),
        (3599.9, "59 min"),
        (3600, "1 h"),
        (3659, "1 h"),
        (3660, "1 h 1 min"),
        (7200, "2 h"),
        (3 * 3600 + 12 * 60, "3 h 12 min"),
        (12_160.25, "3 h 22 min"),  # 194,564 chunks at 16 chunks/s: rounded down, as the minutes are
        (100 * 3600 + 5 * 60, "100 h 5 min"),
    ],
)
def test_fmt_duration(seconds: float, text: str) -> None:
    assert fmt_duration(seconds) == text


# -- arch_rate ---------------------------------------------------------------------------------


def test_arch_rates_table() -> None:
    assert ARCH_RATES == {("darwin", "arm64"): 16.0, ("darwin", "x86_64"): 3.6}
    assert RATE_WINDOW_S == 60.0


def test_arch_rate_by_arguments() -> None:
    assert arch_rate("darwin", "arm64") == 16.0
    assert arch_rate("darwin", "x86_64") == 3.6
    assert arch_rate("linux", "x86_64") is None
    assert arch_rate("linux", "aarch64") is None
    assert arch_rate("darwin", "riscv64") is None
    assert arch_rate("win32", "AMD64") is None


def test_arch_rate_defaults_are_read_at_call_time(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setattr(sys, "platform", "darwin")
    monkeypatch.setattr(platform, "machine", lambda: "arm64")
    assert arch_rate() == 16.0
    monkeypatch.setattr(platform, "machine", lambda: "x86_64")
    assert arch_rate() == 3.6
    monkeypatch.setattr(sys, "platform", "linux")
    assert arch_rate() is None
    assert arch_rate("darwin") == 3.6  # one argument given, the other still read now


# -- the counts, the windowed rate, the ETA and the estimate -------------------------------------


def test_initial_view(worktree: Path) -> None:
    v = BuildProgress(worktree, "test-tiny", clock=Clock()).view()
    assert v.phase == "queued"
    assert (v.total, v.done, v.from_cache) == (None, 0, 0)
    assert (v.rate, v.eta_s, v.holder_pid) == (None, None, None)
    assert v.pid == os.getpid()


def test_add_counts_encoded_and_cached(worktree: Path) -> None:
    p = BuildProgress(worktree, "test-tiny", clock=Clock())
    p.add(4, cached=True)
    p.add(16)
    p.add(16)
    v = p.view()
    assert (v.done, v.from_cache) == (36, 4)


def test_fields_are_the_builds_to_set(worktree: Path) -> None:
    p = BuildProgress(worktree, "test-tiny", clock=Clock())
    p.total = 100
    p.phase = "waiting"
    p.holder_pid = 4242
    v = p.view()
    assert (v.total, v.phase, v.holder_pid) == (100, "waiting", 4242)


def test_rate_over_the_window(worktree: Path) -> None:
    clock = Clock(0.0)
    p = BuildProgress(worktree, "test-tiny", clock=clock)
    assert p.view().rate is None  # nothing encoded yet
    clock.t = 10.0
    p.add(160)
    assert p.view().rate == 16.0


def test_rate_over_several_adds(worktree: Path) -> None:
    clock = Clock(0.0)
    p = BuildProgress(worktree, "test-tiny", clock=clock)
    for t in (2.0, 4.0, 6.0, 8.0, 10.0):
        clock.t = t
        p.add(32)
    assert p.view().rate == 16.0


def test_rate_counts_only_encoded_chunks(worktree: Path) -> None:
    """Cache hits arrive at once, at the start: counted in `done`, but they say nothing about the encoder's speed."""
    clock = Clock(0.0)
    p = BuildProgress(worktree, "test-tiny", clock=clock)
    p.add(1000, cached=True)
    clock.t = 10.0
    p.add(160)
    v = p.view()
    assert v.rate == 16.0
    assert (v.done, v.from_cache) == (1160, 1000)


def test_samples_older_than_the_window_drop_out(worktree: Path) -> None:
    clock = Clock(0.0)
    p = BuildProgress(worktree, "test-tiny", clock=clock)
    clock.t = 10.0
    p.add(160)
    assert p.view().rate == 16.0
    clock.t = 100.0  # the first minute is over: 16 chunks/s no longer says anything
    p.add(50)
    assert p.view().rate is None  # a single sample in the window has no rate yet
    clock.t = 110.0
    p.add(100)
    assert p.view().rate == 10.0  # (310 - 210) / (110 - 100), not (310 - 0) / 110


def test_a_stalled_build_loses_its_rate(worktree: Path) -> None:
    clock = Clock(0.0)
    p = BuildProgress(worktree, "test-tiny", clock=clock)
    clock.t = 10.0
    p.add(160)
    clock.t = RATE_WINDOW_S  # the first sample (the build's start, t=0) is exactly at the window's edge: still in
    assert p.view().rate == 16.0
    clock.t = RATE_WINDOW_S + 0.5  # now only the add at t=10 is left: one sample, no rate
    assert p.view().rate is None


def test_the_sample_window_stays_bounded(worktree: Path) -> None:
    """A build of hours keeps a minute of samples, not one per batch."""
    clock = Clock(0.0)
    p = BuildProgress(worktree, "test-tiny", clock=clock)
    for second in range(1, 3601):
        clock.t = float(second)
        p.add(16)
    assert len(p._samples) <= RATE_WINDOW_S + 1
    assert p.view().rate == 16.0


def test_no_rate_without_elapsed_time(worktree: Path) -> None:
    p = BuildProgress(worktree, "test-tiny", clock=Clock())
    p.add(16)
    p.add(16)
    assert p.view().rate is None


def test_eta_is_remaining_over_rate(worktree: Path) -> None:
    clock = Clock(0.0)
    p = BuildProgress(worktree, "test-tiny", clock=clock)
    p.total = 1000
    p.add(40, cached=True)
    clock.t = 10.0
    p.add(160)
    v = p.view()
    assert v.rate == 16.0
    assert v.eta_s == (1000 - 200) / 16.0  # the cache hits are done too


def test_eta_needs_a_total_and_a_rate(worktree: Path) -> None:
    clock = Clock(0.0)
    p = BuildProgress(worktree, "test-tiny", clock=clock)
    clock.t = 10.0
    p.add(160)
    assert p.view().eta_s is None  # rate, but no total
    p.total = 1000
    assert p.view().eta_s == 52.5
    p.total = 100  # more encoded than the total says: nothing remains, never negative
    assert p.view().eta_s == 0.0
    q = BuildProgress(worktree, "test-tiny", clock=Clock())
    q.total = 1000
    assert q.view().eta_s is None  # total, but no rate


def test_estimate_is_total_over_the_arch_rate(worktree: Path, monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setattr(progress, "arch_rate", lambda: 16.0)
    p = BuildProgress(worktree, "test-tiny", clock=Clock())
    assert p.view().estimate_s is None  # no total yet
    p.total = 194_564
    assert p.view().estimate_s == 194_564 / 16.0
    monkeypatch.setattr(progress, "arch_rate", lambda: None)  # a host with no measured rate
    assert p.view().estimate_s is None


def test_estimate_uses_this_hosts_rate(worktree: Path, monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setattr(sys, "platform", "darwin")
    monkeypatch.setattr(platform, "machine", lambda: "x86_64")
    p = BuildProgress(worktree, "test-tiny", clock=Clock())
    p.total = 3600
    assert p.view().estimate_s == 1000.0


def test_concurrent_adds_lose_nothing(worktree: Path) -> None:
    p = BuildProgress(worktree, "test-tiny", clock=Clock())
    threads = [threading.Thread(target=lambda: [p.add(1) for _ in range(2000)]) for _ in range(4)]
    for t in threads:
        t.start()
    for t in threads:
        t.join()
    assert p.view().done == 8000


def test_cached_add_is_applied_whole(worktree: Path) -> None:
    """done and from_cache move together: a view never sees one without the other."""
    p = BuildProgress(worktree, "test-tiny", clock=Clock())
    stop = threading.Event()
    torn: list[tuple[int, int]] = []

    def watch() -> None:
        while not stop.is_set():
            v = p.view()
            if v.done != v.from_cache:
                torn.append((v.done, v.from_cache))

    watcher = threading.Thread(target=watch)
    watcher.start()
    for _ in range(5000):
        p.add(1, cached=True)
    stop.set()
    watcher.join()
    assert torn == []
    assert p.view().done == p.view().from_cache == 5000


# -- the status line copy ----------------------------------------------------------------------


def test_line_encoding_full() -> None:
    v = view(from_cache=1203, rate=16.1, eta_s=2 * 3600 + 57 * 60)
    assert v.line() == (
        "docs: transformer index building, 12,345 / 194,564 chunks encoded, ETA 2 h 57 min "
        "(16.1 chunks/s; 1,203 from the encode cache)"
    )


def test_line_encoding_without_cache_hits() -> None:
    v = view(rate=16.1, eta_s=2 * 3600 + 57 * 60)
    assert v.line() == (
        "docs: transformer index building, 12,345 / 194,564 chunks encoded, ETA 2 h 57 min (16.1 chunks/s)"
    )


def test_line_encoding_first_window_has_no_rate_and_no_eta() -> None:
    assert view(from_cache=1203).line() == (
        "docs: transformer index building, 12,345 / 194,564 chunks encoded (1,203 from the encode cache)"
    )
    assert view(done=0).line() == "docs: transformer index building, 0 / 194,564 chunks encoded"


def test_line_encoding_unknown_total_has_no_denominator_and_no_eta() -> None:
    assert view(total=None, rate=16.1, from_cache=1203).line() == (
        "docs: transformer index building, 12,345 chunks encoded (16.1 chunks/s; 1,203 from the encode cache)"
    )
    assert view(total=None).line() == "docs: transformer index building, 12,345 chunks encoded"


def test_line_encoding_rate_one_decimal_and_short_eta() -> None:
    v = view(done=190_000, rate=3.6, eta_s=45.0)
    assert v.line() == "docs: transformer index building, 190,000 / 194,564 chunks encoded, ETA 45 s (3.6 chunks/s)"
    assert view(rate=16.0, eta_s=3 * 3600).line().endswith("ETA 3 h (16.0 chunks/s)")


def test_line_queued_with_estimate() -> None:
    v = view(phase="queued", done=0, estimate_s=3 * 3600 + 23 * 60 + 1.0, total=194_564)
    # 194,564 chunks in 12,181 s is 15.97 chunks/s: shown as the integer rate, ~16
    assert v.line() == (
        "docs: transformer index queued; estimated 3 h 23 min for 194,564 chunks at ~16 chunks/s on this host"
    )


def test_line_queued_estimate_rate_is_an_integer() -> None:
    v = view(phase="queued", done=0, total=3600, estimate_s=1000.0)  # 3.6 chunks/s, the Intel rate
    assert v.line() == "docs: transformer index queued; estimated 16 min for 3,600 chunks at ~4 chunks/s on this host"


def test_line_queued_without_an_estimate() -> None:
    assert view(phase="queued", done=0).line() == "docs: transformer index queued"
    assert view(phase="queued", done=0, total=None, estimate_s=100.0).line() == "docs: transformer index queued"
    assert view(phase="queued", done=0, total=194_564).line() == "docs: transformer index queued"
    assert view(phase="queued", done=0, total=0, estimate_s=0.0).line() == "docs: transformer index queued"


def test_line_waiting() -> None:
    assert view(phase="waiting", holder_pid=4242).line() == (
        "docs: transformer index waiting for another doc-search process on this host (pid 4242) to finish encoding"
    )
    assert view(phase="waiting").line() == (
        "docs: transformer index waiting for another doc-search process on this host to finish encoding"
    )


def test_line_saving() -> None:
    assert view(phase="saving", done=194_564).line() == "docs: transformer index saving (194,564 chunks encoded)"


def test_line_survives_odd_values() -> None:
    assert view(phase="whatever").line() == "docs: transformer index whatever"
    assert "ETA" not in view(rate=16.0, eta_s=float("inf")).line()
    assert "ETA" not in view(rate=16.0, eta_s=float("nan")).line()
    assert view(rate=float("nan")).line() == "docs: transformer index building, 12,345 / 194,564 chunks encoded"


def test_as_dict_holds_every_field() -> None:
    v = view(from_cache=3, rate=16.1, eta_s=10.5, estimate_s=20.0, holder_pid=7)
    d = v.as_dict()
    assert d == {
        "phase": "encoding",
        "total": 194_564,
        "done": 12_345,
        "from_cache": 3,
        "rate": 16.1,
        "eta_s": 10.5,
        "estimate_s": 20.0,
        "holder_pid": 7,
        "pid": 4242,
    }
    assert ProgressView(**json.loads(json.dumps(d))) == v


# -- the progress file ---------------------------------------------------------------------------


def test_progress_path_is_per_resolved_worktree(worktree: Path, tmp_path: Path) -> None:
    path = progress_path(worktree)
    assert path.parent == cache_root() / "encode" / "progress"
    assert re.fullmatch(r"[0-9a-f]{16}\.json", path.name)
    link = tmp_path / "link"
    link.symlink_to(worktree)
    assert progress_path(link) == path  # the resolved worktree, not the spelling
    assert progress_path(worktree / ".") == path
    other = tmp_path / "other"
    other.mkdir()
    assert progress_path(other) != path
    assert not cache_root().exists()  # a path is only computed, never created


def test_publish_then_read_round_trips(worktree: Path) -> None:
    clock = Clock(0.0)
    p = BuildProgress(worktree, "gte-modernbert-base", clock=clock)
    p.total = 1000
    p.phase = "encoding"
    p.add(40, cached=True)
    clock.t = 10.0
    p.add(160)
    expected = p.view()
    assert expected.rate == 16.0 and expected.eta_s is not None
    assert read_progress(worktree) is None  # nothing published yet
    p.publish()
    assert read_progress(worktree) == expected
    assert read_progress(worktree).line() == expected.line()  # type: ignore[union-attr]


def test_the_file_holds_the_view_the_worktree_the_model_and_the_pid(worktree: Path) -> None:
    clock = Clock(0.0)
    p = BuildProgress(worktree, "gte-modernbert-base", clock=clock)
    p.total = 500
    clock.t = 10.0
    p.add(160)
    p.publish()
    data = json.loads(progress_path(worktree).read_text(encoding="utf-8"))
    assert data == {
        **p.view().as_dict(),
        "worktree": str(worktree),
        "model": "gte-modernbert-base",
        "pid": os.getpid(),
    }
    assert data["rate"] == 16.0 and data["eta_s"] == (500 - 160) / 16.0  # fixed at publish time


def test_publish_creates_its_directory_and_leaves_no_temp_file(worktree: Path) -> None:
    p = BuildProgress(worktree, "m", clock=Clock())
    assert not cache_root().exists()
    p.publish()
    p.add(1)
    p.publish(force=True)
    assert [f.name for f in progress_path(worktree).parent.iterdir()] == [progress_path(worktree).name]


def test_publish_throttles_to_one_write_a_second(worktree: Path) -> None:
    clock = Clock(500.0)
    p = BuildProgress(worktree, "m", clock=clock)

    def published_done() -> int:
        return json.loads(progress_path(worktree).read_text(encoding="utf-8"))["done"]

    p.add(10)
    p.publish()
    assert published_done() == 10
    p.add(10)
    p.publish()  # the same clock second
    assert published_done() == 10
    clock.t += 0.9
    p.publish()
    assert published_done() == 10
    p.publish(force=True)  # forced: written regardless
    assert published_done() == 20
    p.add(10)
    clock.t += 0.9  # 0.9 s after the forced write: still throttled
    p.publish()
    assert published_done() == 20
    clock.t += 0.2
    p.publish()
    assert published_done() == 30


def test_read_progress_is_none_when_absent(worktree: Path) -> None:
    assert read_progress(worktree) is None


def _published(worktree: Path) -> tuple[BuildProgress, Path]:
    p = BuildProgress(worktree, "m", clock=Clock())
    p.total = 10
    p.add(3)
    p.publish()
    return p, progress_path(worktree)


def test_read_progress_none_for_a_dead_pid(worktree: Path) -> None:
    _, path = _published(worktree)
    child = subprocess.Popen([sys.executable, "-c", "pass"])
    child.wait()  # reaped: the pid is dead (and not yet reused, in any realistic test run)
    data = json.loads(path.read_text(encoding="utf-8"))
    data["pid"] = child.pid
    path.write_text(json.dumps(data), encoding="utf-8")
    assert read_progress(worktree) is None


def test_read_progress_alive_pid_of_a_live_child(worktree: Path) -> None:
    _, path = _published(worktree)
    child = subprocess.Popen([sys.executable, "-c", "import time; time.sleep(30)"])
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
        data["pid"] = child.pid
        path.write_text(json.dumps(data), encoding="utf-8")
        v = read_progress(worktree)
        assert v is not None and v.pid == child.pid
    finally:
        child.kill()
        child.wait()
    assert read_progress(worktree) is None  # and once it is gone, nothing


def test_read_progress_treats_a_permission_error_as_alive(worktree: Path, monkeypatch: pytest.MonkeyPatch) -> None:
    _published(worktree)

    def kill(pid: int, sig: int) -> None:
        raise PermissionError(1, "Operation not permitted")  # another user's process: it exists

    monkeypatch.setattr(os, "kill", kill)
    assert read_progress(worktree) is not None


def test_read_progress_treats_a_missing_process_as_dead(worktree: Path, monkeypatch: pytest.MonkeyPatch) -> None:
    _published(worktree)

    def kill(pid: int, sig: int) -> None:
        raise ProcessLookupError(3, "No such process")

    monkeypatch.setattr(os, "kill", kill)
    assert read_progress(worktree) is None


def test_read_progress_probes_with_signal_zero(worktree: Path, monkeypatch: pytest.MonkeyPatch) -> None:
    _published(worktree)
    probes: list[tuple[int, int]] = []
    monkeypatch.setattr(os, "kill", lambda pid, sig: probes.append((pid, sig)))
    assert read_progress(worktree) is not None
    assert probes == [(os.getpid(), 0)]


@pytest.mark.parametrize(
    "text",
    [
        "",
        "not json",
        "[]",
        "null",
        '"phase"',
        "{}",
        '{"phase": "encoding"}',
    ],
)
def test_read_progress_none_for_a_malformed_file(worktree: Path, text: str) -> None:
    _, path = _published(worktree)
    path.write_text(text, encoding="utf-8")
    assert read_progress(worktree) is None


def test_read_progress_none_for_undecodable_bytes(worktree: Path) -> None:
    _, path = _published(worktree)
    path.write_bytes(b"\xff\xfe\x00{")
    assert read_progress(worktree) is None


@pytest.mark.parametrize(
    ("key", "value"),
    [
        ("phase", 3),
        ("phase", None),
        ("total", "10"),
        ("total", True),
        ("done", "3"),
        ("done", None),
        ("done", 1.5),
        ("done", -1),
        ("from_cache", -1),
        ("total", -1),
        ("from_cache", None),
        ("rate", "fast"),
        ("rate", True),
        ("rate", float("nan")),
        ("eta_s", float("inf")),
        ("estimate_s", [1]),
        ("holder_pid", "4242"),
        ("pid", "4242"),
        ("pid", True),
        ("pid", None),
        ("pid", 0),
        ("pid", -1),
        ("pid", 2**70),
    ],
)
def test_read_progress_none_for_a_field_of_the_wrong_type(worktree: Path, key: str, value: object) -> None:
    _, path = _published(worktree)
    data = json.loads(path.read_text(encoding="utf-8"))
    data[key] = value
    path.write_text(json.dumps(data), encoding="utf-8")
    assert read_progress(worktree) is None


def test_read_progress_none_for_a_missing_field(worktree: Path) -> None:
    _, path = _published(worktree)
    data = json.loads(path.read_text(encoding="utf-8"))
    del data["from_cache"]
    path.write_text(json.dumps(data), encoding="utf-8")
    assert read_progress(worktree) is None


def test_read_progress_none_when_the_path_is_unreadable(worktree: Path) -> None:
    path = progress_path(worktree)
    path.mkdir(parents=True)  # a directory where the file should be
    assert read_progress(worktree) is None


def test_read_progress_accepts_integer_valued_floats(worktree: Path) -> None:
    _, path = _published(worktree)
    data = json.loads(path.read_text(encoding="utf-8"))
    data.update(rate=16, eta_s=5, estimate_s=None, total=None)
    path.write_text(json.dumps(data), encoding="utf-8")
    v = read_progress(worktree)
    assert v is not None
    assert (v.rate, v.eta_s, v.estimate_s, v.total) == (16.0, 5.0, None, None)
    assert isinstance(v.rate, float)


# -- publish and retire never fail a build ------------------------------------------------------


def test_retire_removes_the_file(worktree: Path) -> None:
    p, path = _published(worktree)
    assert read_progress(worktree) is not None
    p.retire()
    assert not path.exists()
    assert read_progress(worktree) is None


def test_retire_without_a_file_is_fine(worktree: Path, caplog: pytest.LogCaptureFixture) -> None:
    p = BuildProgress(worktree, "m", clock=Clock())
    with caplog.at_level(logging.WARNING, logger="doc_search.progress"):
        p.retire()
        p.retire()
    assert caplog.records == []


def test_a_retired_build_does_not_publish_again(worktree: Path) -> None:
    """A late publish (another thread's heartbeat) must not bring a finished build's file back."""
    p, path = _published(worktree)
    p.retire()
    p.add(1)
    p.publish(force=True)
    assert not path.exists()


def test_publish_with_an_unusable_location_warns_once_and_never_raises(
    worktree: Path, tmp_path: Path, monkeypatch: pytest.MonkeyPatch, caplog: pytest.LogCaptureFixture
) -> None:
    blocker = tmp_path / "a-file"
    blocker.write_text("not a directory", encoding="utf-8")
    with monkeypatch.context() as mp:
        mp.setenv("DOC_SEARCH_CACHE_LOCATION", str(blocker / "cache"))  # the directory cannot be made
        p = BuildProgress(worktree, "m", clock=Clock())
        with caplog.at_level(logging.WARNING, logger="doc_search.progress"):
            p.publish(force=True)
            p.publish(force=True)
            p.retire()
        assert read_progress(worktree) is None
    warnings = [r for r in caplog.records if r.levelno == logging.WARNING]
    assert len(warnings) == 1
    assert warnings[0].getMessage().startswith("doc-search: ")


def test_publish_failing_to_replace_cleans_up_and_never_raises(
    worktree: Path, monkeypatch: pytest.MonkeyPatch, caplog: pytest.LogCaptureFixture
) -> None:
    def replace(src: object, dst: object) -> None:
        raise PermissionError(13, "Permission denied")

    monkeypatch.setattr(os, "replace", replace)
    p = BuildProgress(worktree, "m", clock=Clock())
    with caplog.at_level(logging.WARNING, logger="doc_search.progress"):
        p.publish(force=True)
        p.publish(force=True)
    assert len([r for r in caplog.records if r.levelno == logging.WARNING]) == 1
    directory = progress_path(worktree).parent
    assert list(directory.iterdir()) == []  # no temp file left behind


def test_retire_failing_to_unlink_warns_and_never_raises(
    worktree: Path, monkeypatch: pytest.MonkeyPatch, caplog: pytest.LogCaptureFixture
) -> None:
    p, _ = _published(worktree)

    def unlink(self: Path, missing_ok: bool = False) -> None:
        raise PermissionError(13, "Permission denied")

    monkeypatch.setattr(Path, "unlink", unlink)
    with caplog.at_level(logging.WARNING, logger="doc_search.progress"):
        p.retire()
    warnings = [r for r in caplog.records if r.levelno == logging.WARNING]
    assert len(warnings) == 1 and warnings[0].getMessage().startswith("doc-search: ")


def test_a_failed_publish_is_throttled_like_a_good_one(worktree: Path, monkeypatch: pytest.MonkeyPatch) -> None:
    """A broken location is tried once a second, not on every add."""
    calls: list[int] = []

    def replace(src: object, dst: object) -> None:
        calls.append(1)
        raise OSError(5, "I/O error")

    monkeypatch.setattr(os, "replace", replace)
    clock = Clock()
    p = BuildProgress(worktree, "m", clock=clock)
    for _ in range(5):
        p.publish()
    assert len(calls) == 1
    clock.t += 1.5
    p.publish()
    assert len(calls) == 2
