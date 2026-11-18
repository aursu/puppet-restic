#!/usr/bin/env python3
# MANAGED BY PUPPET (restic) - restic repository freshness for node_exporter.
"""restic repository freshness as Prometheus metrics, for the node_exporter textfile collector.

For every repository environment file (`<config-dir>/<name>.env`, written by `restic::repository`)
it lists the snapshots through the `restic-run` wrapper and writes, atomically, one metrics file:

- restic_repository_up{repository}                          1 = the snapshot list could be read
- restic_repository_snapshots{repository}                   number of snapshots
- restic_repository_latest_snapshot_timestamp_seconds{repository}
- restic_tag_latest_snapshot_timestamp_seconds{repository,tag}
- restic_repository_read_duration_seconds{repository}
- restic_metrics_collector_timestamp_seconds                when this collector last ran

The snapshot list is read with `--no-lock`, so it never waits for, or blocks, a running backup or
prune. `restic copy` keeps the original snapshot time, so the latest snapshot of an off-site copy
is as old as the source snapshot it copied - "older than a day" means "the copy did not run".

A repository that cannot be read is reported with `restic_repository_up 0` and the run still
succeeds; only a failure to write the metrics file makes it exit non-zero.

Usage: restic_metrics.py --output FILE [--config-dir DIR] [--runner PATH] [--timeout S]
                         [--repository NAME ...]
"""
from __future__ import annotations

import argparse
import json
import os
import re
import subprocess
import sys
import tempfile
import time
from dataclasses import dataclass, field
from datetime import datetime
from pathlib import Path
from typing import Dict, List, Optional, Sequence, Tuple

DEFAULT_CONFIG_DIR = "/etc/restic"
DEFAULT_RUNNER = "/opt/backup/restic-run"
DEFAULT_TIMEOUT = 300


class ResticTime:
    """Parses the RFC 3339 times restic prints (nanosecond fraction, `Z` or an offset)."""

    _PATTERN = re.compile(r"^(\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2})(\.\d+)?(Z|[+-]\d{2}:\d{2})$")

    @classmethod
    def to_epoch(cls, value: str) -> float:
        match = cls._PATTERN.match(value)
        if not match:
            raise ValueError(f"unexpected restic time: {value!r}")
        base, fraction, zone = match.groups()
        zone = "+0000" if zone == "Z" else zone.replace(":", "")
        moment = datetime.strptime(base + zone, "%Y-%m-%dT%H:%M:%S%z")
        return moment.timestamp() + (float(fraction) if fraction else 0.0)


@dataclass(frozen=True)
class Snapshot:
    time: float
    tags: Tuple[str, ...] = ()

    @classmethod
    def from_json(cls, item: dict) -> "Snapshot":
        tags = item.get("tags") or []
        return cls(time=ResticTime.to_epoch(item["time"]), tags=tuple(str(t) for t in tags))


@dataclass
class RepositoryReport:
    name: str
    up: bool
    duration: float
    snapshots: List[Snapshot] = field(default_factory=list)

    @property
    def count(self) -> int:
        return len(self.snapshots)

    @property
    def latest(self) -> Optional[float]:
        return max((s.time for s in self.snapshots), default=None)

    def latest_by_tag(self) -> Dict[str, float]:
        latest: Dict[str, float] = {}
        for snapshot in self.snapshots:
            for tag in snapshot.tags:
                if snapshot.time > latest.get(tag, float("-inf")):
                    latest[tag] = snapshot.time
        return latest


class ResticReader:
    """Reads the snapshot list of one repository through the restic-run wrapper."""

    def __init__(self, runner: str, timeout: int) -> None:
        self.runner = runner
        self.timeout = timeout

    def read(self, name: str, env_file: Path) -> RepositoryReport:
        started = time.monotonic()
        command = [self.runner, str(env_file), "snapshots", "--json", "--no-lock"]
        try:
            result = subprocess.run(
                command,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                timeout=self.timeout,
                check=False,
            )
        except (OSError, subprocess.TimeoutExpired) as error:
            return self._failed(name, started, f"{type(error).__name__}: {error}")
        if result.returncode != 0:
            stderr = result.stderr.decode("utf-8", "replace").strip()
            return self._failed(name, started, f"exit {result.returncode}: {stderr[-500:]}")
        try:
            items = json.loads(result.stdout.decode("utf-8") or "[]")
            snapshots = [Snapshot.from_json(item) for item in items or []]
        except (ValueError, KeyError, TypeError) as error:
            return self._failed(name, started, f"unreadable snapshot list: {error}")
        return RepositoryReport(name, True, time.monotonic() - started, snapshots)

    @staticmethod
    def _failed(name: str, started: float, reason: str) -> RepositoryReport:
        print(f"restic-metrics: {name}: {reason}", file=sys.stderr)
        return RepositoryReport(name, False, time.monotonic() - started)


class RepositoryCatalog:
    """The repository env files to read: every `*.env` in the config directory, or the named ones."""

    def __init__(self, config_dir: Path, names: Sequence[str]) -> None:
        self.config_dir = config_dir
        self.names = list(names)

    def entries(self) -> List[Tuple[str, Path]]:
        if self.names:
            return [(name, self.config_dir / f"{name}.env") for name in self.names]
        return [(path.stem, path) for path in sorted(self.config_dir.glob("*.env"))]


class MetricsRenderer:
    """Prometheus text exposition format for a list of repository reports."""

    _HELP = {
        "restic_repository_up": "1 if the snapshot list of the repository could be read.",
        "restic_repository_snapshots": "Number of snapshots in the repository.",
        "restic_repository_latest_snapshot_timestamp_seconds": "Time of the newest snapshot.",
        "restic_tag_latest_snapshot_timestamp_seconds": "Time of the newest snapshot with this tag.",
        "restic_repository_read_duration_seconds": "Time taken to read the snapshot list.",
        "restic_metrics_collector_timestamp_seconds": "When the collector last ran.",
    }

    def render(self, reports: Sequence[RepositoryReport], now: float) -> str:
        samples: Dict[str, List[str]] = {metric: [] for metric in self._HELP}
        for report in reports:
            repo = {"repository": report.name}
            samples["restic_repository_up"].append(self._sample(repo, 1 if report.up else 0))
            samples["restic_repository_read_duration_seconds"].append(
                self._sample(repo, round(report.duration, 3))
            )
            if not report.up:
                continue
            samples["restic_repository_snapshots"].append(self._sample(repo, report.count))
            if report.latest is not None:
                samples["restic_repository_latest_snapshot_timestamp_seconds"].append(
                    self._sample(repo, report.latest)
                )
            for tag, latest in sorted(report.latest_by_tag().items()):
                samples["restic_tag_latest_snapshot_timestamp_seconds"].append(
                    self._sample({"repository": report.name, "tag": tag}, latest)
                )
        samples["restic_metrics_collector_timestamp_seconds"].append(self._sample({}, int(now)))

        lines: List[str] = []
        for metric, help_text in self._HELP.items():
            if not samples[metric]:
                continue
            lines.append(f"# HELP {metric} {help_text}")
            lines.append(f"# TYPE {metric} gauge")
            lines.extend(f"{metric}{sample}" for sample in samples[metric])
        return "\n".join(lines) + "\n"

    def _sample(self, labels: Dict[str, str], value: float) -> str:
        if labels:
            inner = ",".join(f'{key}="{self._escape(val)}"' for key, val in labels.items())
            return f"{{{inner}}} {value}"
        return f" {value}"

    @staticmethod
    def _escape(value: str) -> str:
        return value.replace("\\", "\\\\").replace('"', '\\"').replace("\n", "\\n")


class AtomicFileWriter:
    """Writes next to the target and renames, so node_exporter never reads a half-written file."""

    def __init__(self, path: Path) -> None:
        self.path = path

    def write(self, content: str) -> None:
        handle, temporary = tempfile.mkstemp(prefix=f".{self.path.name}.", dir=str(self.path.parent))
        try:
            with os.fdopen(handle, "w", encoding="utf-8") as stream:
                stream.write(content)
            os.chmod(temporary, 0o644)
            os.replace(temporary, str(self.path))
        except BaseException:
            if os.path.exists(temporary):
                os.unlink(temporary)
            raise


class Collector:
    def __init__(self, catalog: RepositoryCatalog, reader: ResticReader, writer: AtomicFileWriter) -> None:
        self.catalog = catalog
        self.reader = reader
        self.writer = writer
        self.renderer = MetricsRenderer()

    def run(self) -> int:
        reports = [self.reader.read(name, env_file) for name, env_file in self.catalog.entries()]
        try:
            self.writer.write(self.renderer.render(reports, time.time()))
        except OSError as error:
            print(f"restic-metrics: cannot write {self.writer.path}: {error}", file=sys.stderr)
            return 1
        return 0


def main(argv: Optional[Sequence[str]] = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--output", required=True, type=Path, help="metrics file (*.prom)")
    parser.add_argument("--config-dir", default=DEFAULT_CONFIG_DIR, type=Path)
    parser.add_argument("--runner", default=DEFAULT_RUNNER)
    parser.add_argument("--timeout", default=DEFAULT_TIMEOUT, type=int, help="seconds per repository")
    parser.add_argument("--repository", action="append", default=[], help="repository name (repeatable)")
    args = parser.parse_args(argv)

    collector = Collector(
        RepositoryCatalog(args.config_dir, args.repository),
        ResticReader(args.runner, args.timeout),
        AtomicFileWriter(args.output),
    )
    return collector.run()


if __name__ == "__main__":
    sys.exit(main())
