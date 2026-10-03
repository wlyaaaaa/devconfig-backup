"""Synthetic live-database and package tests; no host configuration is captured."""

import argparse
import ctypes
import hashlib
import importlib.util
import json
from pathlib import Path
import sqlite3
import subprocess
import threading
import zipfile


def check(value, message):
    if not value:
        raise AssertionError(message)
    print("PASS: " + message, flush=True)


def run_tests(repo, fixture, powershell):
    spec = importlib.util.spec_from_file_location("capture", repo / "DevConfig.Sqlite.py")
    capture = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(capture)
    profile = fixture / "profile"
    codex = profile / ".codex"
    codex.mkdir(parents=True)
    source = codex / "state_1.sqlite"
    writer = sqlite3.connect(source)
    writer.execute("PRAGMA journal_mode=WAL")
    writer.execute("PRAGMA wal_autocheckpoint=0")
    writer.execute("CREATE TABLE data(value, padding)")
    writer.executemany("INSERT INTO data VALUES(0, ?)", [("x" * 4096,)] * 1000)
    writer.commit()
    check(Path(str(source) + "-wal").stat().st_size > 0, "Committed fixture data is present in live WAL")
    writer.execute("INSERT INTO data VALUES(99, 'uncommitted')")
    first = fixture / "first.sqlite"
    capture.capture(source, first)
    with sqlite3.connect(first) as restored:
        check(restored.execute("SELECT count(*) FROM data").fetchone() == (1000,), "Online backup includes committed WAL and excludes the open transaction")
        check(restored.execute("PRAGMA integrity_check").fetchall() == [("ok",)], "Standalone captured database passes integrity_check")
        check(restored.execute("PRAGMA journal_mode").fetchone() == ("delete",), "Captured database needs no WAL or SHM recovery files")
    writer.rollback()

    # Commit through a second real SQLite connection in the middle of backup_step.
    original_connect = sqlite3.connect
    commits = []

    class ConcurrentReader(sqlite3.Connection):
        def backup(self, target, **kwargs):
            callback = kwargs["progress"]

            def during(status, remaining, total):
                if not commits:
                    writer.execute("UPDATE data SET value=1")
                    writer.commit()
                    commits.append(remaining)
                callback(status, remaining, total)

            kwargs["progress"] = during
            return super().backup(target, **kwargs)

    def connect(*args, **kwargs):
        if str(args[0]).startswith("file:"):
            kwargs["factory"] = ConcurrentReader
        return original_connect(*args, **kwargs)

    sqlite3.connect = connect
    second = fixture / "second.sqlite"
    try:
        capture.capture(source, second)
    finally:
        sqlite3.connect = original_connect
    with sqlite3.connect(second) as restored:
        check(commits[0] > 0 and restored.execute("SELECT DISTINCT value FROM data").fetchall() == [(0,)], "A commit between backup steps does not mix database generations")
    check(writer.execute("SELECT DISTINCT value FROM data").fetchall() == [(1,)], "Concurrent source commit actually completed")

    stop = threading.Event()
    started = threading.Event()
    errors = []

    def live_writer():
        connection = sqlite3.connect(source, timeout=1)
        try:
            for version in range(2, 1000):
                if stop.is_set():
                    break
                connection.execute("UPDATE data SET value=?", (version,))
                connection.commit()
                started.set()
        except Exception as exc:
            errors.append(type(exc).__name__)
        finally:
            connection.close()

    thread = threading.Thread(target=live_writer)
    thread.start()
    try:
        check(started.wait(5), "Continuous writer committed before capture")
        third = fixture / "third.sqlite"
        capture.capture(source, third)
        with sqlite3.connect(third) as restored:
            check(len(restored.execute("SELECT DISTINCT value FROM data").fetchall()) == 1, "Capture stays consistent while the source keeps writing")
    finally:
        stop.set()
        thread.join(5)
    check(not thread.is_alive() and not errors, "Concurrent writer finished without hidden failures")

    # End to end: sidecars are omitted only for the successfully captured base;
    # unrelated files remain selected and every archive payload retains its hash.
    (codex / "orphan.sqlite-wal").write_text("independent selected data", encoding="utf-8")
    (codex / "dependency.lock").write_text("dependency version", encoding="utf-8")
    (codex / ".sqlite-maintenance.lock").write_bytes(b"")
    sources = fixture / "sources.psd1"
    sources.write_text("@{HomeDirs=@('.codex');RequiredSources=@('home/.codex');SQLiteBackupRelativePaths=@('home/.codex/*.sqlite');ExcludeRelativePaths=@('home/.codex/.sqlite-maintenance.lock')}", encoding="utf-8")
    output = fixture / "output"

    def backup():
        result = subprocess.run([str(powershell), "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", str(repo / "Backup-DevConfig.ps1"), "-Tier", "Local", "-ProfileRoot", str(profile), "-SourcesFile", str(sources), "-OutputRoot", str(output), "-SkipSystemExport", "-Json"], capture_output=True, text=True, encoding="utf-8", errors="replace", timeout=60)
        receipt = json.loads((output / "state" / "devconfig-local-last.json").read_text(encoding="utf-8-sig"))
        return result, receipt

    result, receipt = backup()
    check(result.returncode == 0 and receipt["status"] == "complete", "Live required SQLite publishes a verified Local package")
    current = output / "out" / "current.json"
    before = current.read_bytes()
    pointer = json.loads(before)
    archive = output / "out" / pointer["package_name"]
    with zipfile.ZipFile(archive) as package:
        manifest = json.loads(package.read("backup-manifest.json"))
        names = {entry["relative_path"] for entry in manifest["files"]}
        check("home/.codex/state_1.sqlite" in names and not any("state_1.sqlite-" in name for name in names), "Only successful online snapshot sidecars are excluded from the payload")
        check({"home/.codex/orphan.sqlite-wal", "home/.codex/dependency.lock"}.issubset(names), "Independent sidecar-shaped data and ordinary lockfiles remain recoverable")
        check("home/.codex/.sqlite-maintenance.lock" not in names, "Exact maintenance mutex is excluded without weakening the required root")
        check(manifest["sqlite_snapshots"] == receipt["sqlite_snapshots"] and manifest["sqlite_snapshots"][0]["integrity_check"] == "ok", "Manifest and run receipt identify the verified SQLite snapshot")
        for entry in manifest["files"]:
            check(hashlib.sha256(package.read(entry["relative_path"])).hexdigest() == entry["sha256"], "Archived bytes match the manifest hash: " + entry["relative_path"])
        restored = fixture / "from-package.sqlite"
        restored.write_bytes(package.read("home/.codex/state_1.sqlite"))
    with sqlite3.connect(restored) as connection:
        check(connection.execute("SELECT count(*) FROM data").fetchone() == (1000,), "Archived SQLite is independently readable with committed records")

    update = fixture / "update.py"
    update.write_text("import sqlite3,sys\nc=sqlite3.connect(sys.argv[1]);c.execute('UPDATE data SET value=123');c.commit();c.close()\n", encoding="utf-8")
    selection = fixture / "selection.ps1"
    quote = lambda path: "'" + str(path).replace("'", "''") + "'"
    selection.write_text("\n".join([
        "$ErrorActionPreference='Stop'",
        ". " + quote(repo / "Backup.Common.ps1"),
        ". " + quote(repo / "DevConfig.Sources.ps1"),
        "$cfg=Import-PowerShellDataFile " + quote(sources),
        "$post={& python -I -B " + quote(update) + " " + quote(source) + ";if($LASTEXITCODE-ne 0){throw 'fixture_update_failed'}}",
        "$r=Invoke-DevConfigSourceCapture $cfg " + quote(profile) + " " + quote(fixture / "selection") + " -PostCapture $post",
        "[ordered]@{changes=$r.changed_after_capture_count;attempts=$r.attempt_count;snapshots=$r.inventory.sqlite_snapshots}|ConvertTo-Json -Depth 4",
    ]), encoding="utf-8-sig")
    result = subprocess.run([str(powershell), "-NoProfile", "-File", str(selection)], capture_output=True, text=True, encoding="utf-8", errors="replace", timeout=60)
    check(result.returncode == 0 and json.loads(result.stdout)["changes"] == 1 and json.loads(result.stdout)["attempts"] == 1, "Committed WAL changes after capture are counted without demanding unchanged live hashes")

    # Persistent SQLite exclusive transaction: no raw-copy fallback or publication.
    writer.close()
    busy = sqlite3.connect(source)
    busy.execute("PRAGMA journal_mode=DELETE")
    busy.execute("BEGIN EXCLUSIVE")
    try:
        result, receipt = backup()
        check(result.returncode != 0 and receipt["status"] == "failed" and receipt["failure"] == "backup_sqlite_capture_failed", "Persistent database occupancy remains a real task failure")
        check(receipt["failure_path"] == "home/.codex/state_1.sqlite" and current.read_bytes() == before, "Busy database names its path and preserves the prior successful package")
    finally:
        busy.rollback()
        busy.close()

    # Actual Windows file sharing denial, with no ACL changes.
    kernel = ctypes.WinDLL("kernel32", use_last_error=True)
    kernel.CreateFileW.argtypes = [ctypes.c_wchar_p, ctypes.c_uint32, ctypes.c_uint32, ctypes.c_void_p, ctypes.c_uint32, ctypes.c_uint32, ctypes.c_void_p]
    kernel.CreateFileW.restype = ctypes.c_void_p
    kernel.CloseHandle.argtypes = [ctypes.c_void_p]
    handle = kernel.CreateFileW(str(source), 0x80000000, 0, None, 3, 0, None)
    check(handle not in (None, ctypes.c_void_p(-1).value), "Synthetic SQLite is held with a real exclusive Windows handle")
    try:
        result, receipt = backup()
        check(result.returncode != 0 and receipt["status"] == "failed" and current.read_bytes() == before, "Unreadable required SQLite remains failed and preserves the prior package")
    finally:
        kernel.CloseHandle(handle)

    source.write_bytes(b"not a SQLite database")
    result, receipt = backup()
    check(result.returncode != 0 and receipt["failure"] == "backup_sqlite_capture_failed" and current.read_bytes() == before, "Corrupt database cannot be published as a successful raw copy")
    failure = None
    try:
        capture.capture(first, fixture / "timeout.sqlite", timeout=0)
    except TimeoutError as exc:
        failure = exc
    check(failure is not None, "Capture deadline aborts a valid database without reporting success")


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--repo", type=Path, required=True)
    parser.add_argument("--fixture", type=Path, required=True)
    parser.add_argument("--powershell", type=Path, required=True)
    args = parser.parse_args()
    run_tests(args.repo, args.fixture, args.powershell)
