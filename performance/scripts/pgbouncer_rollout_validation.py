import concurrent.futures
import json
import os
import pathlib
import re
import statistics
import subprocess
import time
import urllib.error
import urllib.request
from datetime import datetime, timezone

ROOT = pathlib.Path(__file__).resolve().parents[2]
MANIFEST = ROOT / "performance" / "manifests" / "mobile-load-event-pgbouncer.json"
RESULTS_DIR = ROOT / "performance" / "results"
RESULTS_DIR.mkdir(parents=True, exist_ok=True)
REPORT_PATH = RESULTS_DIR / (
    f"pgbouncer-rollout-report-{datetime.now(timezone.utc).strftime('%Y-%m-%dT%H-%M-%SZ')}.json"
)
BASE_URL = "http://127.0.0.1:4100"
DEVICE_ID = "device-0000"


with MANIFEST.open("r", encoding="utf-8") as file_handle:
    manifest = json.load(file_handle)


def run(cmd, timeout=120, check=True, capture=True, cwd=ROOT):
    completed = subprocess.run(
        cmd,
        cwd=str(cwd),
        text=True,
        capture_output=capture,
        timeout=timeout,
        shell=isinstance(cmd, str),
        env=os.environ.copy(),
    )
    if check and completed.returncode != 0:
        raise RuntimeError(
            f"command failed: {cmd}\nstdout:\n{completed.stdout}\nstderr:\n{completed.stderr}"
        )
    return completed


def rpc_scrape():
    cmd = [
        "docker",
        "exec",
        "fastcheck-app-perf",
        "/app/bin/fastcheck",
        "rpc",
        "IO.puts(TelemetryMetricsPrometheus.Core.scrape())",
    ]
    return run(cmd, timeout=30).stdout


def parse_metric(text, name, suffix):
    pattern = re.compile(rf"^{re.escape(name)}_{re.escape(suffix)}\s+([0-9eE+\-.]+)$", re.MULTILINE)
    match = pattern.search(text)
    return float(match.group(1)) if match else None


def pgbouncer_query(sql):
    cmd = (
        "docker exec fastcheck-postgres sh -lc "
        + json.dumps(
            f"PGPASSWORD=postgres psql -A -F ',' -h pgbouncer -p 5432 -U postgres pgbouncer -c \"{sql}\""
        )
    )
    return run(cmd, timeout=30).stdout


def postgres_query(sql):
    cmd = (
        "docker exec fastcheck-postgres sh -lc "
        + json.dumps(
            f"PGPASSWORD=postgres psql -A -F ',' -U postgres -d fastcheck_prod -c \"{sql}\""
        )
    )
    return run(cmd, timeout=30).stdout


def parse_csv_output(text):
    lines = [line for line in text.splitlines() if line.strip()]
    if len(lines) < 2:
        return []

    headers = lines[0].split(",")
    rows = []

    for line in lines[1:]:
        parts = line.split(",")
        if len(parts) != len(headers):
            continue
        rows.append(dict(zip(headers, parts)))

    return rows


def snapshot_metrics():
    scrape = rpc_scrape()
    pools = parse_csv_output(pgbouncer_query("SHOW POOLS;"))
    stats = parse_csv_output(pgbouncer_query("SHOW STATS;"))
    activity = parse_csv_output(
        postgres_query(
            "select state, coalesce(wait_event_type,''), coalesce(wait_event,''), count(*) "
            "from pg_stat_activity where datname = 'fastcheck_prod' "
            "group by state, wait_event_type, wait_event order by count(*) desc;"
        )
    )
    numbackends = parse_csv_output(
        postgres_query(
            "select numbackends, xact_commit, xact_rollback from pg_stat_database "
            "where datname = 'fastcheck_prod';"
        )
    )
    oban = parse_csv_output(
        postgres_query(
            "select count(*) as total, "
            "count(*) filter (where state='available') as available, "
            "count(*) filter (where state='executing') as executing, "
            "count(*) filter (where state='retryable') as retryable "
            "from oban_jobs where queue = 'scan_persistence';"
        )
    )

    return {
        "repo_queue_time_sum": parse_metric(scrape, "fastcheck_repo_query_queue_time", "sum"),
        "repo_queue_time_count": parse_metric(scrape, "fastcheck_repo_query_queue_time", "count"),
        "repo_query_time_sum": parse_metric(scrape, "fastcheck_repo_query_query_time", "sum"),
        "repo_query_time_count": parse_metric(scrape, "fastcheck_repo_query_query_time", "count"),
        "pools": pools,
        "stats": stats,
        "activity": activity,
        "numbackends": numbackends,
        "oban": oban[0] if oban else {},
    }


def login_token():
    body = json.dumps({"event_id": manifest["event_id"], "credential": manifest["credential"]}).encode(
        "utf-8"
    )
    request = urllib.request.Request(
        BASE_URL + "/api/v1/mobile/login",
        data=body,
        headers={"Content-Type": "application/json", "x-perf-device-id": DEVICE_ID},
        method="POST",
    )
    with urllib.request.urlopen(request, timeout=30) as response:
        payload = json.loads(response.read().decode("utf-8"))
    return payload["data"]["token"]


def post_scan(token, scan):
    body = json.dumps({"scans": [scan]}).encode("utf-8")
    request = urllib.request.Request(
        BASE_URL + "/api/v1/mobile/scans",
        data=body,
        headers={
            "Content-Type": "application/json",
            "Authorization": f"Bearer {token}",
            "x-perf-device-id": DEVICE_ID,
        },
        method="POST",
    )
    started = time.perf_counter()

    try:
        with urllib.request.urlopen(request, timeout=30) as response:
            payload = json.loads(response.read().decode("utf-8"))
            status_code = response.status
    except urllib.error.HTTPError as error:
        payload = json.loads(error.read().decode("utf-8")) if error.fp else None
        status_code = error.code

    elapsed_ms = (time.perf_counter() - started) * 1000.0
    return {"http_status": status_code, "payload": payload, "latency_ms": elapsed_ms}


def summarize_scan_results(results):
    http_statuses = {}
    statuses = {}
    messages = {}
    reason_codes = {}

    for item in results:
        http_statuses[str(item["http_status"])] = http_statuses.get(str(item["http_status"]), 0) + 1

        payload = item["payload"] or {}
        rows = (((payload.get("data") or {}).get("results")) or [])
        if rows:
            row = rows[0]
            status = row.get("status", "none")
            statuses[status] = statuses.get(status, 0) + 1
            message = row.get("message", "")
            messages[message] = messages.get(message, 0) + 1
            reason = row.get("reason_code")
            if reason:
                reason_codes[reason] = reason_codes.get(reason, 0) + 1
        else:
            statuses["top_level_error"] = statuses.get("top_level_error", 0) + 1

    latencies = [item["latency_ms"] for item in results]
    ordered = sorted(latencies)
    p95_index = max(0, int(len(ordered) * 0.95) - 1) if ordered else 0

    return {
        "http_statuses": http_statuses,
        "statuses": statuses,
        "messages": messages,
        "reason_codes": reason_codes,
        "latency_ms": {
            "min": min(latencies) if latencies else None,
            "avg": statistics.fmean(latencies) if latencies else None,
            "p95": ordered[p95_index] if ordered else None,
            "max": max(latencies) if latencies else None,
        },
    }


def same_ticket_burst(token, ticket_code, same_idempotency):
    label = "same_idempotency" if same_idempotency else "different_idempotency"

    def build(index):
        if same_idempotency:
            idempotency_key = f"burst-replay-{ticket_code}"
        else:
            idempotency_key = f"burst-business-{ticket_code}-{index}"

        return {
            "ticket_code": ticket_code,
            "idempotency_key": idempotency_key,
            "direction": "in",
            "scanned_at": datetime.now(timezone.utc).isoformat().replace("+00:00", "Z"),
            "entrance_name": "Perf Main",
            "operator_name": f"pgbouncer-{label}",
        }

    scans = [build(index) for index in range(12)]
    with concurrent.futures.ThreadPoolExecutor(max_workers=12) as executor:
        results = list(executor.map(lambda scan: post_scan(token, scan), scans))

    return summarize_scan_results(results)


def run_k6(slice_name, scenarios, extra_env):
    summary_path = RESULTS_DIR / (
        f"k6-{slice_name}-{datetime.now(timezone.utc).strftime('%Y-%m-%dT%H-%M-%SZ')}.json"
    )
    env = os.environ.copy()
    env.update(
        {
            "MANIFEST_PATH": str(MANIFEST),
            "PERF_BASE_URL": BASE_URL,
            "PERF_DEVICE_COUNT": "40",
            "K6_SUMMARY_PATH": str(summary_path),
            "SCENARIOS": scenarios,
        }
    )
    env.update(extra_env)

    completed = subprocess.run(
        ["k6", "run", "performance/k6/mobile_scans.js"],
        cwd=str(ROOT),
        text=True,
        capture_output=True,
        timeout=900,
        env=env,
    )
    if completed.returncode != 0:
        raise RuntimeError(
            f"k6 failed for {slice_name}\nstdout:\n{completed.stdout}\nstderr:\n{completed.stderr}"
        )

    with summary_path.open("r", encoding="utf-8") as file_handle:
        data = json.load(file_handle)

    metrics = data.get("metrics", {})
    return {
        "summary_path": str(summary_path),
        "http_req_duration_p95": metrics.get("http_req_duration", {}).get("values", {}).get("p(95)"),
        "http_req_duration_p99": metrics.get("http_req_duration", {}).get("values", {}).get("p(99)"),
        "http_req_failed_rate": metrics.get("http_req_failed", {}).get("values", {}).get("rate"),
        "success_results": metrics.get("scan_result_success", {}).get("values", {}).get("count", 0),
        "replay_duplicates": metrics.get("scan_result_idempotency_replay_duplicate", {})
        .get("values", {})
        .get("count", 0),
        "business_duplicates": metrics.get("scan_result_business_duplicate", {})
        .get("values", {})
        .get("count", 0),
        "invalid_results": metrics.get("scan_result_invalid", {}).get("values", {}).get("count", 0),
        "retryable_failures": metrics.get("scan_result_retryable_failure", {})
        .get("values", {})
        .get("count", 0),
        "capacity_scan_requests": metrics.get("capacity_scan_requests", {}).get("values", {}).get("count", 0),
        "blocked_rate": metrics.get("capacity_scan_blocked_rate", {}).get("values", {}).get("rate", 0),
    }


def diff_snap(before, after):
    queue_sum = (after["repo_queue_time_sum"] or 0.0) - (before["repo_queue_time_sum"] or 0.0)
    queue_count = (after["repo_queue_time_count"] or 0.0) - (before["repo_queue_time_count"] or 0.0)
    query_sum = (after["repo_query_time_sum"] or 0.0) - (before["repo_query_time_sum"] or 0.0)
    query_count = (after["repo_query_time_count"] or 0.0) - (before["repo_query_time_count"] or 0.0)

    return {
        "repo_queue_time_delta_sum": queue_sum,
        "repo_queue_time_delta_count": queue_count,
        "repo_queue_time_avg_ms": (queue_sum / queue_count) if queue_count else 0.0,
        "repo_query_time_delta_sum": query_sum,
        "repo_query_time_delta_count": query_count,
        "repo_query_time_avg_ms": (query_sum / query_count) if query_count else 0.0,
        "pgbouncer_pools_after": after["pools"],
        "pgbouncer_stats_after": after["stats"],
        "postgres_activity_after": after["activity"],
        "postgres_numbackends_after": after["numbackends"],
        "oban_after": after["oban"],
    }


def main():
    report = {
        "generated_at": datetime.now(timezone.utc).isoformat().replace("+00:00", "Z"),
        "base_url": BASE_URL,
        "manifest": str(MANIFEST),
        "mode_proof": {
            "mobile_scan_ingestion_mode": run(
                ["docker", "exec", "fastcheck-app-perf", "printenv", "MOBILE_SCAN_INGESTION_MODE"],
                timeout=10,
            ).stdout.strip(),
            "database_url": run(
                ["docker", "exec", "fastcheck-app-perf", "printenv", "DATABASE_URL"],
                timeout=10,
            ).stdout.strip(),
            "database_pooling_mode": run(
                ["docker", "exec", "fastcheck-app-perf", "printenv", "DATABASE_POOLING_MODE"],
                timeout=10,
            ).stdout.strip(),
            "oban_notifier": run(
                ["docker", "exec", "fastcheck-app-perf", "printenv", "OBAN_NOTIFIER"],
                timeout=10,
            ).stdout.strip(),
        },
        "slices": {},
    }

    token = login_token()
    report["initial_snapshot"] = snapshot_metrics()

    before = snapshot_metrics()
    same_replay = same_ticket_burst(token, "PGB-000352", same_idempotency=True)
    after = snapshot_metrics()
    report["slices"]["same_ticket_replay_burst"] = {
        "result_mix": same_replay,
        "metrics": diff_snap(before, after),
    }

    time.sleep(5)

    before = snapshot_metrics()
    same_business = same_ticket_burst(token, "PGB-000353", same_idempotency=False)
    after = snapshot_metrics()
    report["slices"]["same_ticket_business_duplicate_burst"] = {
        "result_mix": same_business,
        "metrics": diff_snap(before, after),
    }

    time.sleep(5)

    before = snapshot_metrics()
    duplicate_heavy = run_k6(
        "duplicate-heavy",
        "capacity_baseline",
        {
            "BASELINE_RATE": "20",
            "BASELINE_DURATION": "30s",
            "BASELINE_PREALLOCATED_VUS": "16",
            "BASELINE_MAX_VUS": "32",
        },
    )
    after = snapshot_metrics()
    report["slices"]["duplicate_heavy"] = {
        "k6": duplicate_heavy,
        "metrics": diff_snap(before, after),
    }

    time.sleep(10)
    report["slices"]["duplicate_heavy"]["oban_drain_10s"] = snapshot_metrics()["oban"]

    before = snapshot_metrics()
    short_stability = run_k6(
        "short-stability",
        "capacity_soak",
        {
            "SOAK_RATE": "20",
            "SOAK_DURATION": "60s",
            "SOAK_PREALLOCATED_VUS": "20",
            "SOAK_MAX_VUS": "40",
        },
    )
    after = snapshot_metrics()
    report["slices"]["short_stability"] = {
        "k6": short_stability,
        "metrics": diff_snap(before, after),
    }

    time.sleep(15)
    report["slices"]["short_stability"]["oban_drain_15s"] = snapshot_metrics()["oban"]

    with REPORT_PATH.open("w", encoding="utf-8") as file_handle:
        json.dump(report, file_handle, indent=2)

    print(str(REPORT_PATH))
    print(json.dumps(report, indent=2))


if __name__ == "__main__":
    main()
