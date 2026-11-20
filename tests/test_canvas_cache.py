import importlib.util
import pathlib
import tempfile
import unittest

from aiohttp import web
from aiohttp.test_utils import TestClient, TestServer


path = pathlib.Path(__file__).resolve().parents[1] / "server/comfyui_pocket/canvas_cache.py"
spec = importlib.util.spec_from_file_location("canvas_cache", path)
cache = importlib.util.module_from_spec(spec)
spec.loader.exec_module(cache)


class CanvasCacheTests(unittest.IsolatedAsyncioTestCase):
    async def asyncSetUp(self):
        temp = tempfile.TemporaryDirectory()
        self.addCleanup(temp.cleanup)
        self.script = pathlib.Path(temp.name) / "example.js"
        self.script.write_text("export const example = 1")
        self.nodes = {"stable": {"choices": list(range(500))}, "edited": {"name": "old"}, "gone": {}}

        async def definitions(_):
            return web.json_response(self.nodes)

        self.snapshot = pathlib.Path(temp.name) / "node-definitions.json"
        app = web.Application(middlewares=[cache.canvas_cache(self.snapshot)])
        app.router.add_get("/object_info", definitions)
        app.router.add_get("/api/object_info", definitions)
        app.router.add_static("/extensions/sample", temp.name)
        self.client = TestClient(TestServer(app))
        await self.client.start_server()
        self.addAsyncCleanup(self.client.close)

    async def test_schema_download_revalidation_delta_and_fallback(self):
        first = await self.client.get("/object_info", headers={cache.REVISION: "none"})
        self.assertEqual(await first.json(), self.nodes)
        revision = first.headers[cache.REVISION]
        unchanged = await self.client.get("/api/object_info", headers={cache.REVISION: revision})
        self.assertEqual(unchanged.status, 304)
        self.assertEqual(await unchanged.read(), b"")

        self.nodes["edited"] = {"name": "new"}
        del self.nodes["gone"]
        delta = await self.client.get("/api/object_info", headers={cache.REVISION: revision})
        self.assertEqual(delta.headers[cache.DELTA], "1")
        self.assertEqual(await delta.json(), {"changed": {"edited": {"name": "new"}}, "removed": ["gone"]})
        self.assertNotEqual(delta.headers[cache.REVISION], revision)

        missing = await self.client.get("/object_info", headers={cache.REVISION: "unknown"})
        ordinary = await self.client.get("/object_info")
        separate_user = await self.client.get("/object_info", headers={cache.REVISION: revision, "Comfy-User": "second"})
        for full in (missing, ordinary, separate_user):
            self.assertNotIn(cache.DELTA, full.headers)
            self.assertEqual(await full.json(), self.nodes)
        self.assertNotIn(cache.REVISION, separate_user.headers)

    def test_delta_distinguishes_numeric_and_boolean_values(self):
        self.assertEqual(cache.node_delta(b'{"A":{"default":1}}', b'{"A":{"default":true}}'),
                         b'{"changed":{"A":{"default":true}},"removed":[]}')

    async def test_delta_uses_persisted_baseline_after_comfyui_restart(self):
        first = await self.client.get("/object_info", headers={cache.REVISION: "none"})
        await first.read()
        previous = first.headers[cache.REVISION]

        self.nodes["edited"]["name"] = "updated after restart"
        async def definitions(_):
            return web.json_response(self.nodes)

        restarted = web.Application(middlewares=[cache.canvas_cache(self.snapshot)])
        restarted.router.add_get("/object_info", definitions)
        async with TestClient(TestServer(restarted)) as client:
            diff = await client.get("/object_info", headers={cache.REVISION: previous})
            self.assertEqual(diff.headers[cache.DELTA], "1")
            self.assertEqual(await diff.json(), {"changed": {"edited": {"name": "updated after restart"}}, "removed": []})

    async def test_only_changed_extension_content_is_transferred(self):
        url = "/extensions/sample/example.js"
        browser = await self.client.get(url)
        self.assertNotEqual(browser.headers.get("Cache-Control"), "private, no-cache")
        await browser.read()
        headers = {"User-Agent": f"WebKit {cache.CANVAS_AGENT}"}
        first = await self.client.get(url, headers=headers)
        self.assertEqual(first.headers["Cache-Control"], "private, no-cache")
        self.assertIn("User-Agent", first.headers["Vary"])
        headers["If-None-Match"] = first.headers["ETag"]
        await first.read()
        second = await self.client.get(url, headers=headers)
        self.assertEqual(second.status, 304)
        self.assertEqual(await second.read(), b"")
        self.script.write_text("export const example = 'changed'")
        changed = await self.client.get(url, headers=headers)
        self.assertEqual(changed.status, 200)
        self.assertEqual(await changed.text(), "export const example = 'changed'")
