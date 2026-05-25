"""Test 1: MCP client session against the real SmartTwinMCP server.

Uses fastmcp.Client with in-memory transport (skips OS pipes but exercises the
full MCP protocol: initialize → list_tools → call_tool). This proves the four
catalog meta-tools work end-to-end via the actual MCP layer.
"""
import asyncio, json, os, sys
from pathlib import Path

sys.path.insert(0, "src")
from fastmcp import Client
from smarttwin_mcp.server import build_server


async def main():
    server = build_server(Path("./tools").resolve())
    async with Client(server) as client:
        # 1. initialize
        print("=== initialize ===")
        init = client.initialize_result
        print(f"server: {init.serverInfo.name} v{init.serverInfo.version}")

        # 2. list_tools — proves the 4 catalog meta-tools + direct-exposed tools show up
        print("\n=== list_tools ===")
        tools = await client.list_tools()
        names = sorted(t.name for t in tools)
        print(f"total exposed: {len(tools)}")
        # The 4 catalog meta-tools + 1 reload tool MUST be present
        for required in ("catalog_search", "catalog_describe", "catalog_versions", "catalog_run", "catalog_reload"):
            assert required in names, f"missing meta tool: {required}"
        print(f"  meta tools: all 5 present")
        catalog_only = [n for n in names if not n.startswith("catalog_")]
        print(f"  direct-exposed tools ({len(catalog_only)}): {catalog_only}")

        # 3. catalog_search via the actual MCP call_tool path
        print("\n=== catalog_search('lsdyna') ===")
        r = await client.call_tool("catalog_search", {"query": "lsdyna", "limit": 5})
        result = r.data
        print(f"total_tools in catalog: {result['total_tools']}")
        print(f"hits: {len(result['hits'])}")
        for h in result["hits"]:
            print(f"  - {h['name']:30s} score={h['score']:5.1f}  {h['summary'][:60]}")
        assert any(h["name"] == "submit_lsdyna_job" for h in result["hits"]), "lsdyna search miss"

        # 4. catalog_describe — confirm we get usage doc, schema, examples
        print("\n=== catalog_describe('echo') ===")
        r = await client.call_tool("catalog_describe", {"name": "echo"})
        d = r.data
        print(f"name: {d['name']}@{d['version']} | transport: {d['transport']}")
        print(f"has args_schema: {bool(d.get('args_schema'))}")
        print(f"examples: {len(d['examples'])}")
        assert d["args_schema"]["required"] == ["message"]

        # 5. catalog_run echo — actual execution through MCP
        print("\n=== catalog_run('echo', {message: 'hello via MCP', count: 3}) ===")
        r = await client.call_tool("catalog_run", {
            "name": "echo",
            "args": {"message": "hello via MCP", "count": 3},
        })
        out = r.data
        print(f"ok: {out['ok']} | exit: {out['exit_code']} | tool: {out['tool']}")
        print(f"result: {out['result']}")
        assert out["ok"] is True
        assert out["result"]["echoed"] == ["hello via MCP"] * 3

        # 6. catalog_versions
        print("\n=== catalog_versions('echo') ===")
        r = await client.call_tool("catalog_versions", {"name": "echo"})
        v = r.data
        print(f"latest: {v['latest']} | versions: {v['versions']}")

        # 7. Schema validation rejection — pass an invalid arg, expect ok:false WITH validation message
        print("\n=== catalog_run rejects invalid args ===")
        r = await client.call_tool("catalog_run", {
            "name": "echo",
            "args": {"message": "x", "count": 99999},  # exceeds maximum 100
        })
        out = r.data
        print(f"ok: {out['ok']} | error: {out.get('error', '')[:80]}")
        assert out["ok"] is False
        assert "validation failed" in out["error"]

        # 8. Unknown tool with did-you-mean
        print("\n=== catalog_run('echoo') → did_you_mean ===")
        r = await client.call_tool("catalog_run", {"name": "echoo", "args": {}})
        out = r.data
        print(f"ok: {out['ok']} | did_you_mean: {out.get('did_you_mean', [])}")
        assert out["ok"] is False
        assert "echo" in out.get("did_you_mean", [])

        print("\n=== TEST 1 PASSED ===")


def test_mcp_session_end_to_end():
    """Pytest entry point."""
    asyncio.run(main())


if __name__ == "__main__":
    asyncio.run(main())
