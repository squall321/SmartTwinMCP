"""Test 3: weak-LLM simulation.

Simulates a low-capability LLM that only knows the 4 catalog meta-tools and
follows the discovery flow promised by the guide:

  1. catalog_search(intent)   -> pick top hit
  2. catalog_describe(name)   -> read schema + examples
  3. fill in required args from the first example
  4. catalog_run(name, args)  -> execute

If the user's natural-language intent reaches a sensible tool and runs WITHOUT
a "tool not found" or schema-validation error, the round-trip is considered
successful for that intent. A real LLM would do better; if the deterministic
floor passes, the LLM ceiling is fine.
"""
import asyncio, sys
from pathlib import Path

sys.path.insert(0, "src")
from fastmcp import Client
from smarttwin_mcp.server import build_server


# (natural-language intent, expected tool name in top hits, args overrides)
SCENARIOS = [
    ("repeat the word ping three times",                "echo",                       {"message": "ping", "count": 3}),
    ("submit a simulation job",                         "submit_job",                 None),
    ("submit a raw lsdyna k file to slurm",             "submit_lsdyna_job",          None),
    ("show me recent jobs",                             "list_recent_jobs",           {"limit": 5}),
    ("check the status of job 999999",                  "job_status",                 {"registry_id": 999999}),
    ("tail the slurm logs of job 999999",               "job_logs",                   {"registry_id": 999999}),
    ("list pending inbound webhooks",                   "list_inbound_webhooks",      {"limit": 10}),
    ("acknowledge webhook 2",                           "ack_inbound_webhook",        {"webhook_id": 2, "outcome": "acked"}),
    ("launch a distributed pytorch training",           "submit_distributed_train",   None),
    ("get the cluster health",                          "get_cluster_health",         {}),
]


async def run_one(client, intent, expected_tool, args_override):
    # Step 1: search
    r = await client.call_tool("catalog_search", {"query": intent, "limit": 5})
    hits = r.data["hits"]
    if not hits:
        return False, f"no search hits for '{intent}'"
    hit_names = [h["name"] for h in hits]
    if expected_tool not in hit_names:
        return False, f"expected '{expected_tool}' not in top hits: {hit_names}"

    # Step 2: describe
    r = await client.call_tool("catalog_describe", {"name": expected_tool})
    d = r.data
    schema = d["args_schema"]
    examples = d["examples"]

    # Step 3: build args. Prefer explicit overrides from the scenario.
    # Otherwise fall back to the first example's args.
    if args_override is not None:
        args = args_override
    elif examples:
        args = examples[0]["args"]
    else:
        args = {}

    # Step 4: run
    r = await client.call_tool("catalog_run", {"name": expected_tool, "args": args})
    out = r.data

    # Success criterion for THIS test (which is about the discovery + dispatch
    # plumbing, not whether the underlying solver actually exists on this box):
    # - the tool was found (no 'tool not found' error)
    # - args validation did NOT reject the call
    # We accept ok:false beyond that, since most tools rely on external bins.
    err = (out.get("error") or "")
    if "tool not found" in err.lower():
        return False, f"dispatch failed: {err}"
    if "args validation failed" in err.lower():
        return False, f"schema rejected our args: {err}"
    return True, f"reached tool with valid args; ok={out.get('ok')}"


async def main():
    server = build_server(Path("./tools").resolve())
    async with Client(server) as client:
        passed = failed = 0
        print(f"{'intent':<48}  {'tool':<28}  result")
        print("-" * 110)
        for intent, expected, override in SCENARIOS:
            ok, detail = await run_one(client, intent, expected, override)
            status = "PASS" if ok else "FAIL"
            if ok:
                passed += 1
            else:
                failed += 1
            print(f"{intent[:46]:<48}  {expected:<28}  {status}  {detail[:50]}")

        print(f"\n=== weak-LLM flow: {passed}/{len(SCENARIOS)} reached the right tool with valid args ===")
        if failed:
            sys.exit(1)
        print("=== TEST 3 PASSED ===")


asyncio.run(main())
