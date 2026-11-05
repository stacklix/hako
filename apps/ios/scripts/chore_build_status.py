"""Read the local xkode queue on demand for chore."""

from datetime import datetime, timezone
import json
import logging
import os
from pathlib import Path, PureWindowsPath
import re
import subprocess
import threading
import time


ACTIVE_STATES = {"queued", "running", "stalled"}
STATES = ACTIVE_STATES | {"succeeded", "failed", "cancelled", "interrupted"}
PHASES = ("prepare", "preflight", "build", "sign", "package", "install", "launch", "publish")
PHASE_STATES = {"pending", "running", "succeeded", "failed", "cancelled", "skipped"}


def read_json(path):
    return json.loads(path.read_text(encoding="utf-8-sig"))


def normalized_date(value):
    date = parse_date(value)
    return date.astimezone(timezone.utc).isoformat(timespec="seconds") if date else None


def parse_date(value):
    if not isinstance(value, str):
        return None
    try:
        date = datetime.fromisoformat(value)
    except ValueError:
        return None
    if date.tzinfo is None:
        return None
    return date


def elapsed(value, started, finished, running=False):
    if type(value) in (int, float) and 0 <= value <= 2**31 - 1:
        return value
    start = parse_date(started)
    end = parse_date(finished) or (datetime.now(timezone.utc) if running else None)
    if start and end and end >= start:
        return (end - start).total_seconds()
    return None


def display_name(value):
    return value if isinstance(value, str) and re.fullmatch(r"[\w .+()&-]{1,80}", value) else None


class BuildStatus:
    def __init__(self, config_path):
        self._config_path = config_path
        self._body = None
        self._expires_at = 0.0
        self._lock = threading.Lock()

    def snapshot(self):
        with self._lock:
            if time.monotonic() < self._expires_at:
                return self._body
            try:
                config = read_json(self._config_path)
                snapshot = collect(Path(config["xkode"]), Path(config["project"]))
                self._body = json.dumps(snapshot, separators=(",", ":")).encode("utf-8")
            except (OSError, ValueError, KeyError, subprocess.SubprocessError):
                logging.warning("Could not read the local xkode build queue")
                self._body = None
            self._expires_at = time.monotonic() + 2
            return self._body


def collect(xkode, project):
    process = subprocess.run(
        [str(xkode), "tasks", "list"],
        cwd=project.parent,
        stdout=subprocess.PIPE,
        stderr=subprocess.DEVNULL,
        encoding="utf-8-sig",
        env={**os.environ, "PYTHONUTF8": "1"},
        creationflags=getattr(subprocess, "CREATE_NO_WINDOW", 0),
        timeout=5,
        check=True,
    )
    tasks = json.loads(process.stdout)["tasks"]
    root = project.parents[2]
    deliveries = {}
    for path in (root / "build").glob("ios*/delivery-status.json"):
        try:
            delivery = read_json(path)
            expected = path.with_name("expected-build.txt")
            build = expected.read_text(encoding="utf-8-sig").strip() if expected.is_file() else None
            deliveries[delivery["jobId"]] = (delivery, build)
        except (OSError, ValueError, KeyError):
            continue

    rows = []
    for task in tasks:
        application = task.get("application") or {}
        identifier = task.get("id", "")
        created = normalized_date(task.get("created_utc"))
        if not re.fullmatch(r"[0-9a-f]{32}", identifier) or not created or task.get("state") not in STATES:
            continue
        target = display_name(application.get("target")) or "本地构建"
        project_path = application.get("project")
        project_name = display_name(PureWindowsPath(project_path).stem) if isinstance(project_path, str) else None
        delivery, expected = deliveries.get(identifier, ({}, None))
        rows.append(public_task(task, identifier, target, project_name, created, delivery, expected))

    rows.sort(key=lambda row: row["createdAt"], reverse=True)
    return {
        "updatedAt": datetime.now(timezone.utc).isoformat(timespec="seconds"),
        "active": [row for row in rows if row["state"] in ACTIVE_STATES],
        "history": [row for row in rows if row["state"] not in ACTIVE_STATES][:3],
    }


def public_task(task, identifier, target, project, created, delivery, expected):
    state = task["state"]
    current = task.get("current_stage")
    result = task.get("result") or {}
    error = task.get("error") or {}
    partial = error.get("partial_result") or {}
    build = ((result or partial).get("build") or {}).get("project", {}).get("build_number") or expected
    stages = {}
    durations = {}
    for phase, stage in (task.get("stages") or {}).items():
        if phase in PHASES and stage.get("state") in PHASE_STATES:
            stages[phase] = stage["state"]
            duration = elapsed(stage.get("elapsed_seconds"), stage.get("started_utc"),
                               stage.get("finished_utc"), state == "running" and stage["state"] == "running")
            if duration is not None:
                durations[phase] = duration
    if current in PHASES and state == "running":
        stages[current] = "running"
    if state == "succeeded" and result.get("ipa"):
        if delivery.get("publicVerified") is True:
            stages["publish"] = "succeeded"
        elif delivery.get("status") == "failed":
            stages["publish"] = "failed"
        elif delivery.get("status") == "publishing" and recently_updated(delivery):
            stages["publish"] = "running"
            state, current = "running", "publish"
        else:
            stages["publish"] = "pending"
    elif state not in ACTIVE_STATES:
        stages["publish"] = "skipped"
    replaced_by = task.get("replaced_by") or ""
    return {
        "id": identifier,
        "target": target,
        "project": project,
        "createdAt": created,
        "build": build if isinstance(build, str) and re.fullmatch(r"[0-9]{1,10}(?:\.[0-9]{1,10}){0,2}", build) else None,
        "state": state,
        "currentStage": current if current in PHASES else None,
        "failedStage": error["stage"] if error.get("stage") in PHASES else None,
        "replacedBy": replaced_by if re.fullmatch(r"[0-9a-f]{32}", replaced_by) else None,
        "cancellationRequested": task.get("cancellation_requested") is True,
        "elapsedSeconds": elapsed((result or partial).get("elapsed_seconds"), task.get("started_utc"),
                                  task.get("finished_utc"), task["state"] == "running"),
        "stageDurations": durations,
        "stages": stages,
    }


def recently_updated(delivery):
    updated = normalized_date(delivery.get("updatedAt"))
    return updated is not None and (
        datetime.now(timezone.utc) - datetime.fromisoformat(updated)
    ).total_seconds() < 180
