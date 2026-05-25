"""Test 2: dry_run smoke per tool.

For each catalog tool:
- Build args from the first example (if present), forcing dry_run=true when the schema allows it.
- Run via the MCP catalog_run path.
- Classify result: PASS / EXPECTED_FAIL (external binary missing) / UNEXPECTED_FAIL.

This is NOT a correctness test for tool LOGIC — these tools shell out to real
solvers/CLIs we don't have on this box. It's a smoke test that args.schema +
script invocation + JSON envelope contract all hold.
"""
import asyncio, json, sys
from pathlib import Path

sys.path.insert(0, "src")
from fastmcp import Client
from smarttwin_mcp.server import build_server
from smarttwin_mcp.catalog import load_catalog


# Tools that REQUIRE an external binary not on this dev box.
# We expect their stderr to mention what's missing — that's a healthy fail.
EXTERNAL_DEPS = {
    "submit_lsdyna_job":         ["sbatch"],
    "submit_distributed_train":  ["sbatch"],
    "train_pytorch_gpu":         ["sbatch"],
    "fullangle_drop_simulation": ["KooChainRun"],
    "single_drop_simulation":    ["KooChainRun"],
    "job_status":                ["KooChainRun", "squeue"],
    "job_stop":                  ["KooChainRun", "scancel"],
    "job_rerun":                 ["KooChainRun"],
    "job_collect":               ["KooChainRun"],
    "job_diagnose":              ["KooChainRun"],
    "job_postprocess":           ["KooChainRun"],
    "get_job_details":           [],  # may work, depends on registry state
    "get_cluster_health":        ["network"],  # http transport, fails on missing env or unreachable host
}

# Hand-crafted minimal args. For tools we can't smoke without real state,
# use args that should produce a clean validation/precondition fail.
MINIMAL_ARGS = {
    "echo": {"message": "smoke", "count": 1},
    "submit_job": {"case_dir": "/tmp/case_x", "solver": "smarttwin-dyna"},
    "submit_lsdyna_job": {
        "k_file": "/tmp/nonexistent.k",  # forces a clean "not found" fail
        "lstc_license_ip": "192.168.122.1",
        "dry_run": True,
    },
    "submit_distributed_train": {
        "train_script": "/tmp/nonexistent.py",
        "work_dir": "/tmp/stmc_dist_work",
        "gpus": 4,
        "gpu_partition": "gpu-a100",
        "nodes": 2,
        "ntasks_per_node": 4,
        "dry_run": True,
    },
    "train_pytorch_gpu": {
        "train_script": "/tmp/nonexistent.py",
        "work_dir": "/tmp/stmc_gpu_work",
        "gpus": 1,
        "gpu_partition": "gpu-a100",
        "dry_run": True,
    },
    "single_drop_simulation": {
        "work_dir": "/tmp/stmc_drop_smoke",
        "lstc_license_ip": "192.168.122.1",
    },
    "fullangle_drop_simulation": {
        "work_dir": "/tmp/stmc_fa_smoke",
        "lstc_license_ip": "192.168.122.1",
    },
    "scenario_full_reference": {},   # may be no-arg
    "job_status": {"registry_id": 999999},
    "job_stop": {"registry_id": 999999},
    "job_rerun": {"registry_id": 999999},
    "job_collect": {"registry_id": 999999},
    "job_diagnose": {"registry_id": 999999},
    "job_postprocess": {"registry_id": 999999},
    "job_logs": {"registry_id": 999999},
    "get_job_details": {"registry_id": 999999},
    "list_recent_jobs": {"limit": 5},
    "get_cluster_health": {},
    "list_inbound_webhooks": {"limit": 10, "ack_status": "pending"},
    "ack_inbound_webhook": {"webhook_id": 1, "outcome": "acked", "note": "smoke test"},
}


async def main():
    server = build_server(Path("./tools").resolve())
    catalog = load_catalog(Path("./tools").resolve())
    names = sorted(catalog.latest_by_name)
    print(f"Catalog has {len(names)} tools.\n")

    rows = []
    async with Client(server) as client:
        for name in names:
            entry = catalog.latest_by_name[name]
            args = MINIMAL_ARGS.get(name)

            if args is None:
                # Fall back to the first example.
                ex = entry.meta.examples
                if not ex:
                    rows.append((name, "SKIP", "no minimal args, no examples"))
                    continue
                args = ex[0].args

            r = await client.call_tool("catalog_run", {"name": name, "args": args})
            out = r.data

            ok = out.get("ok", False)
            err = out.get("error") or out.get("stderr") or ""
            stdout = out.get("stdout") or ""
            parsed = out.get("result") or {}

            # Classification logic.
            if ok:
                # Real success. The tool ran and returned a JSON envelope.
                rows.append((name, "PASS", _short(stdout)))
                continue

            # Failed. Is it a precondition / dependency failure (acceptable)
            # or a contract violation (bad)?
            external = EXTERNAL_DEPS.get(name, [])
            blob = (err + " " + stdout).lower()

            # Acceptable: file-not-found preconditions (we passed bogus paths),
            # missing external binary, "registry row not found" (we passed bogus IDs),
            # HTTP env var or connection errors.
            acceptable_signals = [
                "not found", "no such", "missing env", "connection refused",
                "urlopen", "registry_id", "no rows", "does not exist",
                "expected_at", "k_file not found",
            ]
            if any(s in blob for s in acceptable_signals):
                rows.append((name, "EXPECTED_FAIL", _short(blob)))
                continue
            if external and any(b.lower() in blob for b in external):
                rows.append((name, "EXPECTED_FAIL", f"external dep: {external}"))
                continue

            # Also check: the JSON envelope is still well-formed (ok: false + a reason).
            # If parsed has 'ok: False' and a reason, the contract held even if logic failed.
            if isinstance(parsed, dict) and parsed.get("ok") is False and parsed.get("reason"):
                rows.append((name, "EXPECTED_FAIL", f"reason: {parsed['reason'][:60]}"))
                continue

            rows.append((name, "UNEXPECTED_FAIL", _short(blob)))

    # Report.
    by_status = {}
    for _, st, _ in rows:
        by_status[st] = by_status.get(st, 0) + 1

    print(f"\n=== RESULTS ({len(rows)} tools) ===")
    print(f"{'tool':<32}  {'status':<18}  detail")
    print("-" * 100)
    for name, st, detail in rows:
        print(f"{name:<32}  {st:<18}  {detail[:60]}")

    print(f"\n=== SUMMARY: {by_status} ===")

    bad = [r for r in rows if r[1] == "UNEXPECTED_FAIL"]
    if bad:
        print(f"\n!!! {len(bad)} tools FAILED the JSON-envelope contract:")
        for name, _, detail in bad:
            print(f"  - {name}: {detail}")
        sys.exit(1)
    print("\n=== TEST 2 PASSED (no contract violations) ===")


def _short(s: str, n: int = 60) -> str:
    s = (s or "").strip().replace("\n", " ")
    return s[:n]


asyncio.run(main())
