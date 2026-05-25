"""Test 4: proxy / mount.

Builds a separate "gateway" FastMCP server, mounts SmartTwinMCP under it with
a namespace, then connects a client to the GATEWAY (not to SmartTwinMCP directly).
Proves an external aggregator can re-expose our catalog without code changes.
"""
import asyncio, sys
from pathlib import Path

sys.path.insert(0, "src")
from fastmcp import Client, FastMCP
from fastmcp.server import create_proxy
from smarttwin_mcp.server import build_server


async def _mount_with_prefix():
    backend = build_server(Path("./tools").resolve())
    gateway = FastMCP(name="GatewayMCP")
    gateway.mount(backend, namespace="stmc")  # tools appear as stmc_<name>

    async with Client(gateway) as client:
        tools = await client.list_tools()
        names = [t.name for t in tools]
        print(f"gateway sees {len(tools)} tools.")
        # Every backend tool must appear with the 'stmc_' prefix.
        for required in ("stmc_catalog_search", "stmc_catalog_describe", "stmc_catalog_run", "stmc_echo"):
            assert required in names, f"missing prefixed tool: {required} (got: {sorted(names)[:5]}...)"
        print(f"  found namespaced meta-tools and direct-exposed echo")

        # Call through the gateway.
        r = await client.call_tool("stmc_catalog_search", {"query": "lsdyna", "limit": 3})
        hits = r.data["hits"]
        assert any(h["name"] == "submit_lsdyna_job" for h in hits)
        print(f"  catalog_search through proxy returned {len(hits)} hits, expected one found")

        r = await client.call_tool("stmc_catalog_run", {
            "name": "echo",
            "args": {"message": "via gateway", "count": 2},
        })
        out = r.data
        assert out["ok"] is True
        assert out["result"]["echoed"] == ["via gateway"] * 2
        print(f"  catalog_run through proxy executed echo: {out['result']}")


async def _as_proxy_in_memory():
    """as_proxy() wraps an in-memory FastMCP as a transparent proxy."""
    backend = build_server(Path("./tools").resolve())
    proxy = create_proxy(backend, name="TransparentProxy")

    async with Client(proxy) as client:
        tools = await client.list_tools()
        names = {t.name for t in tools}
        # No namespace this time — names should be identical.
        assert "catalog_search" in names
        assert "echo" in names
        print(f"as_proxy: {len(tools)} tools mirrored without renaming")

        r = await client.call_tool("catalog_run", {"name": "echo", "args": {"message": "transparent"}})
        out = r.data
        assert out["ok"] is True
        print(f"  call through transparent proxy: ok={out['ok']}, echoed={out['result']['echoed']}")


async def main():
    print("=== Test 4a: gateway with mount(prefix='stmc') ===")
    await _mount_with_prefix()
    print()
    print("=== Test 4b: FastMCP.as_proxy() transparent ===")
    await _as_proxy_in_memory()
    print()
    print("=== TEST 4 PASSED ===")


def test_proxy_and_mount_end_to_end():
    """Pytest entry point."""
    asyncio.run(main())


if __name__ == "__main__":
    asyncio.run(main())
