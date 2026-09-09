"""Filesystem watcher that refreshes an XREF index after .xref file changes."""

from __future__ import annotations

from collections.abc import Callable
from pathlib import Path
from threading import Lock, Timer

from watchdog.events import FileSystemEvent, FileSystemEventHandler
from watchdog.observers import Observer


class _XrefEventHandler(FileSystemEventHandler):
    def __init__(self, schedule_refresh: Callable[[], None]) -> None:
        super().__init__()
        self._schedule_refresh = schedule_refresh

    def on_any_event(self, event: FileSystemEvent) -> None:
        if not event.is_directory and Path(event.src_path).suffix.lower() == ".xref":
            self._schedule_refresh()


class XrefWatcher:
    """Debounce XREF file events before invoking an index refresh callback."""

    def __init__(
        self,
        root: Path,
        refresh: Callable[[], None],
        debounce_seconds: float = 0.25,
    ) -> None:
        self._root = root
        self._refresh = refresh
        self._debounce_seconds = debounce_seconds
        self._observer = Observer()
        self._timer: Timer | None = None
        self._lock = Lock()

    def start(self) -> None:
        self._observer.schedule(_XrefEventHandler(self._schedule_refresh), str(self._root), recursive=True)
        self._observer.start()

    def stop(self) -> None:
        with self._lock:
            if self._timer:
                self._timer.cancel()
                self._timer = None
        self._observer.stop()
        self._observer.join()

    def _schedule_refresh(self) -> None:
        with self._lock:
            if self._timer:
                self._timer.cancel()
            self._timer = Timer(self._debounce_seconds, self._run_refresh)
            self._timer.daemon = True
            self._timer.start()

    def _run_refresh(self) -> None:
        with self._lock:
            self._timer = None
        self._refresh()