"""Capture one live SQLite database without emitting its content or error text."""

import argparse
from contextlib import closing
import json
from pathlib import Path
import sqlite3
import time


def capture(source: Path, target: Path, timeout: float = 15.0) -> None:
    deadline = time.monotonic() + timeout

    def bounded(*_):
        if time.monotonic() >= deadline:
            raise TimeoutError("sqlite_capture_timeout")
        return 0

    # mode=ro includes committed WAL pages; immutable=1 would miss live WAL.
    with closing(sqlite3.connect(source.resolve().as_uri() + "?mode=ro", uri=True,
                                timeout=0.25, isolation_level=None)) as reader:
        reader.execute("PRAGMA query_only=ON")
        reader.execute("BEGIN")
        # Establish one read snapshot before the incremental backup starts.
        reader.execute("SELECT count(*) FROM sqlite_schema").fetchone()
        target.parent.mkdir(parents=True, exist_ok=True)
        with target.open("xb"):
            pass
        with closing(sqlite3.connect(target, timeout=0.25)) as writer:
            reader.backup(writer, pages=256, progress=bounded, sleep=0.05)
            writer.set_progress_handler(bounded, 1000)
            if writer.execute("PRAGMA journal_mode=DELETE").fetchone()[0] != "delete":
                raise sqlite3.DatabaseError("sqlite_standalone_mode_failed")
            if writer.execute("PRAGMA integrity_check").fetchall() != [("ok",)]:
                raise sqlite3.DatabaseError("sqlite_integrity_failed")
            bounded()


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("source", type=Path)
    parser.add_argument("target", type=Path)
    parser.add_argument("--timeout", type=float, default=15.0)
    args = parser.parse_args()
    try:
        capture(args.source, args.target, args.timeout)
    except (OSError, sqlite3.Error, TimeoutError) as exc:
        code = getattr(exc, "sqlite_errorcode", None)
        reason = "timeout" if isinstance(exc, TimeoutError) else "sqlite_error" if isinstance(exc, sqlite3.Error) else "io_error"
        print(json.dumps({"status": "failed", "reason": reason, "sqlite_error_code": code}))
        return 1
    print(json.dumps({"status": "complete", "method": "sqlite_online_backup", "integrity_check": "ok"}))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
