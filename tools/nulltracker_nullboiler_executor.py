#!/usr/bin/env python3
"""nullTracker -> nullBoiler bridge executor.

Claims tasks from nullTracker by role, executes each claim through nullBoiler,
and reports lifecycle back to nullTracker (events, artifacts, transition/fail).
"""

from __future__ import annotations

import argparse
import json
import os
import pathlib
import re
import sys
import threading
import time
import urllib.error
import urllib.request
from dataclasses import dataclass
from typing import Any, Dict, List, Optional, Tuple


def log(message: str) -> None:
    print(f"[tracker-boiler] {message}", file=sys.stderr, flush=True)


class HttpClient:
    def __init__(self, base_url: str, timeout_sec: float) -> None:
        self.base_url = base_url.rstrip("/")
        self.timeout_sec = timeout_sec

    def request_json(
        self,
        method: str,
        path_or_url: str,
        payload: Optional[Dict[str, Any]] = None,
        headers: Optional[Dict[str, str]] = None,
    ) -> Tuple[int, Optional[Any], str]:
        url = path_or_url if path_or_url.startswith("http://") or path_or_url.startswith("https://") else f"{self.base_url}{path_or_url}"
        req_headers: Dict[str, str] = {"Accept": "application/json"}
        if headers:
            req_headers.update(headers)

        body: Optional[bytes] = None
        if payload is not None:
            body = json.dumps(payload, separators=(",", ":"), ensure_ascii=True).encode("utf-8")
            req_headers["Content-Type"] = "application/json"

        req = urllib.request.Request(url=url, method=method, headers=req_headers, data=body)

        try:
            with urllib.request.urlopen(req, timeout=self.timeout_sec) as resp:
                status = resp.getcode()
                raw = resp.read().decode("utf-8", errors="replace")
        except urllib.error.HTTPError as err:
            status = err.code
            raw = err.read().decode("utf-8", errors="replace")
        except urllib.error.URLError as err:
            raise RuntimeError(f"{method} {url} failed: {err.reason}") from err

        parsed: Optional[Any] = None
        if raw:
            try:
                parsed = json.loads(raw)
            except json.JSONDecodeError:
                parsed = None

        return status, parsed, raw


@dataclass
class ClaimContext:
    task: Dict[str, Any]
    tracker_run_id: str
    lease_id: str
    lease_token: str
    agent_id: str
    agent_role: str


class HeartbeatLoop:
    def __init__(
        self,
        tracker_client: HttpClient,
        lease_id: str,
        lease_token: str,
        interval_sec: float,
    ) -> None:
        self.tracker_client = tracker_client
        self.lease_id = lease_id
        self.lease_token = lease_token
        self.interval_sec = interval_sec
        self._stop = threading.Event()
        self.failed = threading.Event()
        self._thread = threading.Thread(target=self._run, daemon=True)

    def start(self) -> None:
        self._thread.start()

    def stop(self) -> None:
        self._stop.set()
        self._thread.join(timeout=5.0)

    def _run(self) -> None:
        headers = {"Authorization": f"Bearer {self.lease_token}"}
        while not self._stop.wait(self.interval_sec):
            status, _, raw = self.tracker_client.request_json(
                "POST",
                f"/leases/{self.lease_id}/heartbeat",
                payload=None,
                headers=headers,
            )
            if status != 200:
                log(f"lease heartbeat failed (lease_id={self.lease_id}, status={status}, body={raw[:200]})")
                self.failed.set()
                return


def sanitize_filename(value: str) -> str:
    cleaned = re.sub(r"[^a-zA-Z0-9._-]+", "_", value).strip("._")
    return cleaned or "task"


class Executor:
    def __init__(self, args: argparse.Namespace) -> None:
        self.args = args
        self.tracker = HttpClient(args.tracker_base, args.http_timeout_sec)
        self.boiler = HttpClient(args.boiler_base, args.http_timeout_sec)
        self.boiler_headers = {"Authorization": f"Bearer {args.boiler_token}"} if args.boiler_token else None
        self.work_dir = pathlib.Path(args.work_dir).resolve()
        self.work_dir.mkdir(parents=True, exist_ok=True)
        self.worker_tags = parse_worker_tags(args.worker_tags, args.agent_role)

    def claim_task(self) -> Optional[ClaimContext]:
        payload = {
            "agent_id": self.args.agent_id,
            "agent_role": self.args.agent_role,
            "lease_ttl_ms": self.args.lease_ttl_ms,
        }
        status, data, raw = self.tracker.request_json("POST", "/leases/claim", payload=payload)

        if status == 204:
            return None
        if status != 200 or not isinstance(data, dict):
            log(f"claim failed: status={status} body={raw[:300]}")
            return None

        try:
            task = data["task"]
            run = data["run"]
            lease_id = data["lease_id"]
            lease_token = data["lease_token"]
        except KeyError as err:
            log(f"claim response missing field: {err}")
            return None

        return ClaimContext(
            task=task,
            tracker_run_id=run["id"],
            lease_id=lease_id,
            lease_token=lease_token,
            agent_id=self.args.agent_id,
            agent_role=self.args.agent_role,
        )

    def post_tracker_event(self, ctx: ClaimContext, kind: str, data: Dict[str, Any]) -> None:
        headers = {"Authorization": f"Bearer {ctx.lease_token}"}
        payload = {"kind": kind, "data": data}
        status, _, raw = self.tracker.request_json(
            "POST",
            f"/runs/{ctx.tracker_run_id}/events",
            payload=payload,
            headers=headers,
        )
        if status not in (200, 201):
            log(f"event post failed: run={ctx.tracker_run_id} kind={kind} status={status} body={raw[:200]}")

    def fail_tracker_run(self, ctx: ClaimContext, error_text: str, usage: Optional[Dict[str, Any]] = None) -> None:
        headers = {"Authorization": f"Bearer {ctx.lease_token}"}
        payload: Dict[str, Any] = {"error": error_text}
        if usage is not None:
            payload["usage"] = usage
        status, _, raw = self.tracker.request_json(
            "POST",
            f"/runs/{ctx.tracker_run_id}/fail",
            payload=payload,
            headers=headers,
        )
        if status != 200:
            log(f"fail run failed: tracker_run={ctx.tracker_run_id} status={status} body={raw[:200]}")

    def transition_tracker_run(self, ctx: ClaimContext, trigger: str, usage: Dict[str, Any]) -> bool:
        headers = {"Authorization": f"Bearer {ctx.lease_token}"}
        payload = {"trigger": trigger, "usage": usage}
        status, _, raw = self.tracker.request_json(
            "POST",
            f"/runs/{ctx.tracker_run_id}/transition",
            payload=payload,
            headers=headers,
        )
        if status != 200:
            log(
                "transition failed: "
                f"tracker_run={ctx.tracker_run_id} trigger={trigger} status={status} body={raw[:300]}"
            )
            return False
        return True

    def resolve_transition_trigger(self, task_id: str) -> Optional[str]:
        if self.args.success_trigger:
            return self.args.success_trigger

        status, data, raw = self.tracker.request_json("GET", f"/tasks/{task_id}", payload=None)
        if status != 200 or not isinstance(data, dict):
            log(f"failed to load task transitions task_id={task_id} status={status} body={raw[:200]}")
            return None

        transitions = data.get("available_transitions")
        if not isinstance(transitions, list) or not transitions:
            return None

        first = transitions[0]
        if not isinstance(first, dict):
            return None
        trigger = first.get("trigger")
        return trigger if isinstance(trigger, str) and trigger else None

    def create_boiler_run(self, ctx: ClaimContext) -> str:
        task = ctx.task

        input_data: Dict[str, Any] = {
            "agent_id": ctx.agent_id,
            "agent_role": ctx.agent_role,
            "task_id": task.get("id"),
            "task_title": task.get("title"),
            "task_description": task.get("description"),
            "task_stage": task.get("stage"),
            "task_priority": task.get("priority"),
            "task_metadata": task.get("metadata", {}),
            "tracker_run_id": ctx.tracker_run_id,
            "tracker_lease_id": ctx.lease_id,
        }

        prompt_template = (
            "Role: {{input.agent_role}}\n"
            "Task ID: {{input.task_id}}\n"
            "Title: {{input.task_title}}\n"
            "Description:\n{{input.task_description}}\n\n"
            "Stage: {{input.task_stage}}\n"
            "Priority: {{input.task_priority}}\n"
            "Metadata JSON: {{input.task_metadata}}\n\n"
            "Deliver a concise production-ready result."
        )

        run_payload = {
            "input": input_data,
            "steps": [
                {
                    "id": "execute",
                    "type": "task",
                    "worker_tags": self.worker_tags,
                    "prompt_template": prompt_template,
                    "retry": {"max_attempts": 1},
                }
            ],
        }

        status, data, raw = self.boiler.request_json(
            "POST",
            "/runs",
            payload=run_payload,
            headers=self.boiler_headers,
        )
        if status != 201 or not isinstance(data, dict) or not isinstance(data.get("id"), str):
            raise RuntimeError(f"nullboiler run create failed: status={status} body={raw[:400]}")
        return data["id"]

    def poll_boiler_run(self, ctx: ClaimContext, boiler_run_id: str, heartbeat: HeartbeatLoop) -> Dict[str, Any]:
        last_run_status: Optional[str] = None
        step_statuses: Dict[str, str] = {}

        while True:
            if heartbeat.failed.is_set():
                raise RuntimeError("tracker lease heartbeat failed during nullboiler run polling")

            status, data, raw = self.boiler.request_json(
                "GET",
                f"/runs/{boiler_run_id}",
                payload=None,
                headers=self.boiler_headers,
            )
            if status != 200 or not isinstance(data, dict):
                raise RuntimeError(f"nullboiler run poll failed: run={boiler_run_id} status={status} body={raw[:300]}")

            run_status = data.get("status")
            if isinstance(run_status, str) and run_status != last_run_status:
                self.post_tracker_event(
                    ctx,
                    "nullboiler.run_status",
                    {"nullboiler_run_id": boiler_run_id, "status": run_status},
                )
                last_run_status = run_status

            steps = data.get("steps", [])
            if isinstance(steps, list):
                for step in steps:
                    if not isinstance(step, dict):
                        continue
                    step_id = step.get("id")
                    step_status = step.get("status")
                    if not isinstance(step_id, str) or not isinstance(step_status, str):
                        continue
                    prev = step_statuses.get(step_id)
                    if prev != step_status:
                        step_statuses[step_id] = step_status
                        self.post_tracker_event(
                            ctx,
                            "nullboiler.step_status",
                            {
                                "nullboiler_run_id": boiler_run_id,
                                "step_id": step_id,
                                "status": step_status,
                            },
                        )

            if run_status in ("completed", "failed", "cancelled"):
                return data

            time.sleep(self.args.poll_interval_sec)

    def create_tracker_artifact(self, ctx: ClaimContext, report_path: pathlib.Path, boiler_run_id: str) -> None:
        headers = {"Authorization": f"Bearer {ctx.lease_token}"}
        payload = {
            "task_id": ctx.task.get("id"),
            "run_id": ctx.tracker_run_id,
            "kind": "nullboiler_report",
            "uri": f"file://{report_path}",
            "meta": {
                "source": "nullboiler_executor",
                "nullboiler_run_id": boiler_run_id,
            },
        }
        status, _, raw = self.tracker.request_json("POST", "/artifacts", payload=payload, headers=headers)
        if status not in (200, 201):
            log(f"artifact create failed: status={status} body={raw[:200]}")

    def write_report(self, ctx: ClaimContext, boiler_run_id: str, run_payload: Dict[str, Any]) -> pathlib.Path:
        task_title = str(ctx.task.get("title", "task"))
        file_name = f"{sanitize_filename(ctx.tracker_run_id)}_{sanitize_filename(task_title)}.md"
        file_path = self.work_dir / file_name

        lines: List[str] = []
        lines.append(f"# Task {ctx.task.get('id')}")
        lines.append("")
        lines.append(f"- tracker_run_id: {ctx.tracker_run_id}")
        lines.append(f"- nullboiler_run_id: {boiler_run_id}")
        lines.append(f"- status: {run_payload.get('status')}")
        lines.append("")
        lines.append("## Task")
        lines.append("")
        lines.append(f"Title: {ctx.task.get('title')}")
        lines.append("")
        lines.append("Description:")
        lines.append(str(ctx.task.get("description", "")))
        lines.append("")

        if run_payload.get("error_text"):
            lines.append("## Run Error")
            lines.append("")
            lines.append(str(run_payload.get("error_text")))
            lines.append("")

        steps = run_payload.get("steps", [])
        if isinstance(steps, list):
            lines.append("## Steps")
            lines.append("")
            for step in steps:
                if not isinstance(step, dict):
                    continue
                lines.append(f"### {step.get('def_step_id')} ({step.get('id')})")
                lines.append(f"- type: {step.get('type')}")
                lines.append(f"- status: {step.get('status')}")
                if step.get("error_text"):
                    lines.append(f"- error: {step.get('error_text')}")

                output_json = step.get("output_json")
                if output_json is not None:
                    lines.append("")
                    lines.append("Output JSON:")
                    lines.append("```json")
                    try:
                        lines.append(json.dumps(output_json, indent=2, ensure_ascii=True))
                    except TypeError:
                        lines.append(str(output_json))
                    lines.append("```")
                lines.append("")

        file_path.write_text("\n".join(lines), encoding="utf-8")
        return file_path

    def process_claim(self, ctx: ClaimContext) -> None:
        task_id = str(ctx.task.get("id"))
        log(f"claimed task_id={task_id} tracker_run_id={ctx.tracker_run_id} role={ctx.agent_role}")
        self.post_tracker_event(
            ctx,
            "executor.claimed",
            {"agent_id": ctx.agent_id, "agent_role": ctx.agent_role, "task_id": task_id},
        )

        heartbeat = HeartbeatLoop(
            tracker_client=self.tracker,
            lease_id=ctx.lease_id,
            lease_token=ctx.lease_token,
            interval_sec=self.args.heartbeat_interval_sec,
        )
        heartbeat.start()

        try:
            boiler_run_id = self.create_boiler_run(ctx)
        except Exception as err:
            self.fail_tracker_run(ctx, f"nullboiler run create failed: {err}")
            heartbeat.stop()
            return

        self.post_tracker_event(
            ctx,
            "nullboiler.started",
            {"nullboiler_run_id": boiler_run_id, "worker_tags": self.worker_tags},
        )

        try:
            run_payload = self.poll_boiler_run(ctx, boiler_run_id, heartbeat)
        except Exception as err:
            self.fail_tracker_run(
                ctx,
                f"nullboiler polling failed: {err}",
                usage={"nullboiler_run_id": boiler_run_id},
            )
            heartbeat.stop()
            return

        report_path = self.write_report(ctx, boiler_run_id, run_payload)
        self.create_tracker_artifact(ctx, report_path, boiler_run_id)

        status = run_payload.get("status")
        self.post_tracker_event(
            ctx,
            "nullboiler.finished",
            {
                "nullboiler_run_id": boiler_run_id,
                "status": status,
                "report_file": str(report_path),
                "heartbeat_failed": heartbeat.failed.is_set(),
            },
        )

        if status == "completed":
            trigger = self.resolve_transition_trigger(task_id)
            if not trigger:
                self.fail_tracker_run(
                    ctx,
                    "task completed in nullboiler but no available transition trigger",
                    usage={"nullboiler_run_id": boiler_run_id},
                )
                heartbeat.stop()
                return

            transitioned = self.transition_tracker_run(
                ctx,
                trigger=trigger,
                usage={"nullboiler_run_id": boiler_run_id, "report_file": str(report_path)},
            )
            if not transitioned:
                self.fail_tracker_run(
                    ctx,
                    "task completed in nullboiler but transition failed",
                    usage={"nullboiler_run_id": boiler_run_id},
                )
        else:
            error_text = str(run_payload.get("error_text") or f"nullboiler run status={status}")
            self.fail_tracker_run(
                ctx,
                error_text,
                usage={"nullboiler_run_id": boiler_run_id, "report_file": str(report_path)},
            )

        heartbeat.stop()

    def run(self) -> None:
        processed = 0
        while True:
            claim = self.claim_task()
            if claim is None:
                time.sleep(self.args.claim_sleep_sec)
                continue

            self.process_claim(claim)
            processed += 1
            if self.args.max_tasks > 0 and processed >= self.args.max_tasks:
                log(f"max tasks reached: {processed}")
                return


def parse_worker_tags(raw: str, default_role: str) -> List[str]:
    if not raw.strip():
        return [default_role]
    tags = [part.strip() for part in raw.split(",") if part.strip()]
    return tags if tags else [default_role]


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="nullTracker -> nullBoiler bridge executor")
    parser.add_argument("--tracker-base", default=os.environ.get("TRACKER_BASE", "http://127.0.0.1:7700"))
    parser.add_argument("--boiler-base", default=os.environ.get("NULLBOILER_BASE", "http://127.0.0.1:8080"))
    parser.add_argument("--agent-id", default=os.environ.get("AGENT_ID"), required=os.environ.get("AGENT_ID") is None)
    parser.add_argument("--agent-role", default=os.environ.get("AGENT_ROLE"), required=os.environ.get("AGENT_ROLE") is None)
    parser.add_argument("--worker-tags", default=os.environ.get("NULLBOILER_WORKER_TAGS", ""))
    parser.add_argument("--boiler-token", default=os.environ.get("NULLBOILER_TOKEN", ""))
    parser.add_argument("--success-trigger", default=os.environ.get("SUCCESS_TRIGGER", ""))
    parser.add_argument("--lease-ttl-ms", type=int, default=int(os.environ.get("LEASE_TTL_MS", "300000")))
    parser.add_argument("--heartbeat-interval-sec", type=float, default=float(os.environ.get("HEARTBEAT_INTERVAL_SEC", "20")))
    parser.add_argument("--poll-interval-sec", type=float, default=float(os.environ.get("POLL_INTERVAL_SEC", "2")))
    parser.add_argument("--claim-sleep-sec", type=float, default=float(os.environ.get("CLAIM_SLEEP_SEC", "2")))
    parser.add_argument("--http-timeout-sec", type=float, default=float(os.environ.get("HTTP_TIMEOUT_SEC", "30")))
    parser.add_argument("--max-tasks", type=int, default=int(os.environ.get("MAX_TASKS", "0")))
    parser.add_argument(
        "--work-dir",
        default=os.environ.get("WORK_DIR", ""),
        help="Directory for execution reports (default: ./runtime/nullboiler-executor-<role>)",
    )
    args = parser.parse_args()
    if not args.work_dir:
        args.work_dir = f"./runtime/nullboiler-executor-{args.agent_role}"
    return args


def main() -> int:
    args = parse_args()
    executor = Executor(args)
    log(
        "started "
        f"agent_id={args.agent_id} agent_role={args.agent_role} "
        f"tracker={args.tracker_base} nullboiler={args.boiler_base} tags={executor.worker_tags}"
    )
    executor.run()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
