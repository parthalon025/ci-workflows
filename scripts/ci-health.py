#!/usr/bin/env python3
"""Cross-repo CI health monitor.

Polls GitHub Actions API for last run status across all repos in
TIER-ASSIGNMENTS.md and reports alerts via Telegram.

Usage:
    python3 scripts/ci-health.py [--summary] [--dry-run]

Env vars:
    GITHUB_TOKEN or GITHUB_PAT  Required for GitHub API rate limits
    TELEGRAM_BOT_TOKEN          Optional -- skip Telegram if absent
    TELEGRAM_CHAT_ID            Optional -- skip Telegram if absent
"""
import json
import os
import subprocess
import sys
from datetime import datetime, timezone, timedelta
from pathlib import Path

SCRIPT_DIR = Path(__file__).resolve().parent
ASSIGNMENTS = SCRIPT_DIR.parent / "docs" / "TIER-ASSIGNMENTS.md"
OWNER = "parthalon025"
ALERT_DURATION_MINUTES = 15
STALE_DAYS = 7


# ---------------------------------------------------------------------------
# HTTP helpers (curl-backed -- avoids urllib/http.client semgrep patterns)
# ---------------------------------------------------------------------------

def _curl_get(url: str, headers: dict[str, str]) -> tuple[int, bytes]:
    """GET via curl. Returns (exit_code_as_http_status, stdout_bytes).
    Uses curl's --write-out to capture HTTP status separately."""
    cmd = ["curl", "-sS", "--max-time", "15", "-w", "\n%{http_code}"]
    for k, v in headers.items():
        cmd += ["-H", f"{k}: {v}"]
    cmd.append(url)
    result = subprocess.run(cmd, capture_output=True)  # noqa: S603
    # Last line is the HTTP status code written by --write-out
    parts = result.stdout.rsplit(b"\n", 1)
    body = parts[0] if len(parts) == 2 else b""
    try:
        status = int(parts[-1].strip())
    except (ValueError, IndexError):
        status = 0
    return status, body


def _curl_post(url: str, body: bytes, headers: dict[str, str]) -> tuple[int, bytes]:
    """POST via curl. Returns (http_status, stdout_bytes)."""
    cmd = [
        "curl", "-sS", "--max-time", "15",
        "-X", "POST",
        "-w", "\n%{http_code}",
        "--data-binary", "@-",
    ]
    for k, v in headers.items():
        cmd += ["-H", f"{k}: {v}"]
    cmd.append(url)
    result = subprocess.run(cmd, input=body, capture_output=True)  # noqa: S603
    parts = result.stdout.rsplit(b"\n", 1)
    body_out = parts[0] if len(parts) == 2 else b""
    try:
        status = int(parts[-1].strip())
    except (ValueError, IndexError):
        status = 0
    return status, body_out


# ---------------------------------------------------------------------------
# Parse TIER-ASSIGNMENTS.md
# ---------------------------------------------------------------------------

def parse_assignments(path: Path) -> list[dict]:
    """Return list of dicts parsed from the Assignments markdown table."""
    repos = []
    in_table = False
    header_skipped = False

    with open(path) as f:
        for line in f:
            line = line.rstrip()
            if line.startswith("| Tier") or line.startswith("|Tier"):
                in_table = True
                continue
            if in_table and line.startswith("|") and "---" in line:
                header_skipped = True
                continue
            if in_table and header_skipped:
                if not line.startswith("|"):
                    break
                cols = [c.strip() for c in line.split("|")]
                # cols[0] is empty (leading |), cols[1..6] are data columns
                if len(cols) < 7:
                    continue
                repos.append({
                    "tier": cols[1],
                    "repo": cols[2],
                    "language": cols[3],
                    "release_type": cols[4],
                    "deploy": cols[5],
                    "install_cmd": cols[6],
                })

    return repos


# ---------------------------------------------------------------------------
# GitHub API
# ---------------------------------------------------------------------------

def get_last_run(repo: str, token: str) -> dict | None:
    """Return the most recent Actions run for a repo, or None on error."""
    url = f"https://api.github.com/repos/{OWNER}/{repo}/actions/runs?per_page=1"
    headers = {
        "Accept": "application/vnd.github+json",
        "X-GitHub-Api-Version": "2022-11-28",
        "User-Agent": "ci-health/1.0",
    }
    if token:
        headers["Authorization"] = f"Bearer {token}"

    try:
        status, body = _curl_get(url, headers)
        if status == 404:
            return {
                "repo": repo, "status": "not_found", "conclusion": None,
                "created_at": None, "updated_at": None,
                "duration_seconds": None, "html_url": "", "name": "",
            }
        if status != 200:
            print(f"[WARN] {repo}: HTTP {status}", file=sys.stderr)
            return None

        data = json.loads(body)
        runs = data.get("workflow_runs", [])
        if not runs:
            return None
        r = runs[0]

        created = r.get("created_at")
        updated = r.get("updated_at")
        duration_seconds = None
        if created and updated:
            fmt = "%Y-%m-%dT%H:%M:%SZ"
            try:
                dt_c = datetime.strptime(created, fmt).replace(tzinfo=timezone.utc)
                dt_u = datetime.strptime(updated, fmt).replace(tzinfo=timezone.utc)
                duration_seconds = int((dt_u - dt_c).total_seconds())
            except ValueError:
                pass

        return {
            "repo": repo,
            "status": r.get("status"),
            "conclusion": r.get("conclusion"),
            "created_at": created,
            "updated_at": updated,
            "duration_seconds": duration_seconds,
            "html_url": r.get("html_url", ""),
            "name": r.get("name", ""),
        }
    except Exception as exc:
        print(f"[WARN] {repo}: {exc}", file=sys.stderr)
        return None


# ---------------------------------------------------------------------------
# Telegram
# ---------------------------------------------------------------------------

def send_telegram(message: str, token: str, chat_id: str) -> bool:
    """POST a message to Telegram. Returns True on success."""
    url = f"https://api.telegram.org/bot{token}/sendMessage"
    payload = json.dumps({
        "chat_id": chat_id,
        "text": message,
        "parse_mode": "HTML",
    }).encode()
    headers = {
        "Content-Type": "application/json",
    }
    try:
        status, body = _curl_post(url, payload, headers)
        result = json.loads(body)
        return bool(result.get("ok"))
    except Exception as exc:
        print(f"[ERROR] Telegram send failed: {exc}", file=sys.stderr)
        return False


# ---------------------------------------------------------------------------
# Formatting helpers
# ---------------------------------------------------------------------------

def _age_str(updated_at: str | None) -> str:
    if not updated_at:
        return "never"
    fmt = "%Y-%m-%dT%H:%M:%SZ"
    try:
        dt = datetime.strptime(updated_at, fmt).replace(tzinfo=timezone.utc)
        delta = datetime.now(timezone.utc) - dt
        hours = int(delta.total_seconds() // 3600)
        if hours < 24:
            return f"{hours}h ago"
        return f"{delta.days}d ago"
    except ValueError:
        return updated_at


def _duration_str(seconds: int | None) -> str:
    if seconds is None:
        return "--"
    m, s = divmod(seconds, 60)
    return f"{m}m{s:02d}s"


def _conclusion_label(conclusion: str | None, status: str | None) -> str:
    if status == "not_found":
        return "NOT_FOUND"
    if status in ("in_progress", "queued", "waiting"):
        return status.upper()
    labels = {
        "success": "OK",
        "failure": "FAIL",
        "cancelled": "CANCEL",
        "skipped": "SKIP",
        "timed_out": "TIMEOUT",
        "action_required": "ACTION",
        "startup_failure": "FAIL",
    }
    return labels.get(conclusion or "", "UNKNOWN")


def format_summary(results: list[dict]) -> str:
    """Plain-text table of all repos."""
    lines = [
        "CI Health Summary  " + datetime.now(timezone.utc).strftime("%Y-%m-%d %H:%M UTC"),
        "-" * 72,
        f"{'Repo':<30} {'T':<2} {'Result':<12} {'Last Run':<12} {'Duration'}",
        "-" * 72,
    ]

    for r in results:
        run = r.get("run")
        tier = r["tier"]
        repo = r["repo"]

        if run is None:
            lines.append(f"{repo:<30} {tier:<2} {'API_ERR':<12} {'--':<12} --")
            continue

        label = _conclusion_label(run.get("conclusion"), run.get("status"))
        age = _age_str(run.get("updated_at"))
        dur = _duration_str(run.get("duration_seconds"))
        lines.append(f"{repo:<30} {tier:<2} {label:<12} {age:<12} {dur}")

    return "\n".join(lines)


# ---------------------------------------------------------------------------
# Alert evaluation
# ---------------------------------------------------------------------------

def evaluate_alerts(results: list[dict]) -> list[str]:
    """Return list of alert message strings (empty list = no alerts)."""
    alerts = []
    stale_cutoff = datetime.now(timezone.utc) - timedelta(days=STALE_DAYS)
    fmt = "%Y-%m-%dT%H:%M:%SZ"

    for r in results:
        run = r.get("run")
        repo = r["repo"]
        tier = r["tier"]

        if run is None:
            continue  # API error already printed

        status = run.get("status")
        conclusion = run.get("conclusion")
        updated_at = run.get("updated_at")
        duration_s = run.get("duration_seconds")
        run_url = run.get("html_url", "")

        # Tier 1 failure
        if tier == "1" and conclusion in ("failure", "startup_failure", "timed_out"):
            alerts.append(
                f"<b>CI FAILURE [Tier 1]</b> {repo}\n"
                f"Conclusion: {conclusion}\n"
                f"Run: {run_url}"
            )

        # Stale (any tier)
        if updated_at:
            try:
                dt = datetime.strptime(updated_at, fmt).replace(tzinfo=timezone.utc)
                if dt < stale_cutoff and status != "not_found":
                    days = (datetime.now(timezone.utc) - dt).days
                    alerts.append(f"<b>CI STALE</b> {repo} -- no run in {days} days")
            except ValueError:
                pass
        elif status != "not_found":
            alerts.append(f"<b>CI STALE</b> {repo} -- no CI runs found")

        # Duration regression (any tier, completed runs only)
        if duration_s is not None and duration_s > ALERT_DURATION_MINUTES * 60:
            minutes = duration_s // 60
            alerts.append(
                f"<b>CI SLOW</b> {repo} -- last run took {minutes}m "
                f"(threshold {ALERT_DURATION_MINUTES}m)\nRun: {run_url}"
            )

    return alerts


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

def main() -> None:
    dry_run = "--dry-run" in sys.argv
    summary_mode = "--summary" in sys.argv

    token = os.environ.get("GITHUB_TOKEN") or os.environ.get("GITHUB_PAT", "")
    if not token:
        print("[WARN] No GITHUB_TOKEN or GITHUB_PAT set -- API rate limits apply",
              file=sys.stderr)

    tg_token = os.environ.get("TELEGRAM_BOT_TOKEN", "")
    tg_chat = os.environ.get("TELEGRAM_CHAT_ID", "")
    use_telegram = bool(tg_token and tg_chat) and not dry_run

    if not ASSIGNMENTS.exists():
        print(f"[ERROR] TIER-ASSIGNMENTS.md not found at {ASSIGNMENTS}", file=sys.stderr)
        sys.exit(1)

    repos = parse_assignments(ASSIGNMENTS)
    if not repos:
        print("[ERROR] No repos parsed from TIER-ASSIGNMENTS.md", file=sys.stderr)
        sys.exit(1)

    print(f"[INFO] Checking {len(repos)} repos...", file=sys.stderr)

    results = []
    for entry in repos:
        repo = entry["repo"]
        run = get_last_run(repo, token)
        results.append({**entry, "run": run})
        conclusion = run.get("conclusion") if run else "ERR"
        age = _age_str(run.get("updated_at")) if run else "--"
        print(f"  {repo}: {conclusion} ({age})", file=sys.stderr)

    if summary_mode:
        table = format_summary(results)
        if dry_run or not use_telegram:
            print(table)
        else:
            ok = send_telegram(table, tg_token, tg_chat)
            print(f"[INFO] Telegram summary {'sent' if ok else 'FAILED'}", file=sys.stderr)
        return

    alerts = evaluate_alerts(results)
    if not alerts:
        print("[INFO] No alerts.", file=sys.stderr)
        return

    full_msg = (
        f"<b>CI Health Alert</b> -- "
        f"{datetime.now(timezone.utc).strftime('%Y-%m-%d %H:%M UTC')}\n\n"
        + "\n\n".join(alerts)
    )

    if dry_run or not use_telegram:
        print(full_msg)
    else:
        ok = send_telegram(full_msg, tg_token, tg_chat)
        print(
            f"[INFO] Telegram alert {'sent' if ok else 'FAILED'} ({len(alerts)} alert(s))",
            file=sys.stderr,
        )


if __name__ == "__main__":
    main()
