"""Capture one live SQLite database without emitting its content or error text."""

import argparse
from contextlib import closing
import json
from pathlib import Path
import sqlite3
import sys
import time


def set_stage(diagnostic, stage):
    diagnostic["stage"] = stage
    print(json.dumps({"schema": "devconfig.sqlite-stage.v1", "stage": stage}),
          file=sys.stderr, flush=True)


def capture(source: Path, target: Path, timeout: float = 120.0, diagnostic=None,
            stall_timeout: float = 30.0) -> None:
    diagnostic = {} if diagnostic is None else diagnostic
    diagnostic["deadline_expired"] = False
    set_stage(diagnostic, "source_open")
    deadline = time.monotonic() + timeout
    last_progress = time.monotonic()
    best_remaining = None

    def bounded(*_):
        if time.monotonic() >= deadline:
            diagnostic["deadline_expired"] = True
            raise TimeoutError("sqlite_capture_timeout")
        return 0

    def backup_progress(status, remaining, _total):
        nonlocal last_progress, best_remaining
        bounded()
        now = time.monotonic()
        # A completed step may itself take longer than the stall allowance.
        # Credit its real progress before testing for a stalled backup. Busy,
        # repeated pages and restarted work cannot extend the stall allowance.
        if status in (sqlite3.SQLITE_OK, sqlite3.SQLITE_DONE) and (
                best_remaining is None or remaining < best_remaining):
            best_remaining = remaining
            last_progress = now
        if now - last_progress >= stall_timeout:
            diagnostic["deadline_expired"] = True
            raise TimeoutError("sqlite_capture_stalled")

    # mode=ro includes committed WAL pages; immutable=1 would miss live WAL.
    with closing(sqlite3.connect(source.resolve().as_uri() + "?mode=ro", uri=True,
                                timeout=0.25, isolation_level=None)) as reader:
        set_stage(diagnostic, "source_read")
        reader.execute("PRAGMA query_only=ON")
        reader.execute("BEGIN")
        # Establish one read snapshot before the incremental backup starts.
        reader.execute("SELECT count(*) FROM sqlite_schema").fetchone()
        set_stage(diagnostic, "target_create")
        target.parent.mkdir(parents=True, exist_ok=True)
        with target.open("xb"):
            pass
        set_stage(diagnostic, "target_open")
        with closing(sqlite3.connect(target, timeout=0.25)) as writer:
            set_stage(diagnostic, "online_backup")
            reader.backup(writer, pages=256, progress=backup_progress, sleep=0.05)
            writer.set_progress_handler(bounded, 1000)
            set_stage(diagnostic, "standalone_mode")
            if writer.execute("PRAGMA journal_mode=DELETE").fetchone()[0] != "delete":
                raise sqlite3.DatabaseError("sqlite_standalone_mode_failed")
            set_stage(diagnostic, "integrity_check")
            if writer.execute("PRAGMA integrity_check").fetchall() != [("ok",)]:
                raise sqlite3.DatabaseError("sqlite_integrity_failed")
            bounded()


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("source", type=Path)
    parser.add_argument("target", type=Path)
    parser.add_argument("--timeout", type=float, default=120.0)
    args = parser.parse_args()
    diagnostic = {}
    started = time.monotonic()
    try:
        capture(args.source, args.target, args.timeout, diagnostic)
    except (OSError, sqlite3.Error, TimeoutError) as exc:
        code = getattr(exc, "sqlite_errorcode", None)
        # sqlite3 converts exceptions in a progress handler into SQLITE_INTERRUPT.
        reason = "timeout" if isinstance(exc, TimeoutError) or diagnostic.get("deadline_expired") else "sqlite_error" if isinstance(exc, sqlite3.Error) else "io_error"
        print(json.dumps({"status": "failed", "stage": diagnostic["stage"], "reason": reason,
                          "sqlite_error_code": code, "sqlite_error_name": getattr(exc, "sqlite_errorname", None),
                          "os_error_code": getattr(exc, "winerror", None) or getattr(exc, "errno", None),
                          "elapsed_ms": round((time.monotonic() - started) * 1000)}))
        return 1
    print(json.dumps({"status": "complete", "method": "sqlite_online_backup", "integrity_check": "ok"}))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
