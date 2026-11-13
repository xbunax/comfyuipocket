import importlib.util
import json
import pathlib
import sys
import tempfile
import types
import unittest

from aiohttp import web
from aiohttp.test_utils import TestClient, TestServer

ROOT = pathlib.Path(__file__).resolve().parents[1]


class RouteTests(unittest.IsolatedAsyncioTestCase):
    async def asyncSetUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        root = pathlib.Path(self.temp.name)

        class Users:
            def get_request_user_filepath(self, request, file):
                user = request.headers.get("comfy-user", "default")
                if user not in ("default", "second"):
                    raise KeyError(user)
                return str(root / user / file)

        self.prompt_server = types.SimpleNamespace(routes=web.RouteTableDef(), user_manager=Users())
        previous = sys.modules.get("server")
        server = types.ModuleType("server")
        server.PromptServer = types.SimpleNamespace(instance=self.prompt_server)
        sys.modules["server"] = server
        self.addCleanup(lambda: sys.modules.__setitem__("server", previous) if previous else sys.modules.pop("server", None))
        package = types.ModuleType("pocket_test_plugin")
        package.__path__ = [str(ROOT / "server/comfyui_pocket")]
        sys.modules["pocket_test_plugin"] = package
        for part in ("catalog", "routes"):
            name = f"pocket_test_plugin.{part}"
            spec = importlib.util.spec_from_file_location(name, ROOT / f"server/comfyui_pocket/{part}.py")
            module = importlib.util.module_from_spec(spec)
            sys.modules[name] = module
            spec.loader.exec_module(module)
        self.routes_module = sys.modules["pocket_test_plugin.routes"]
        self.routes_module.register_routes()
        app = web.Application()
        app.add_routes(self.prompt_server.routes)
        self.client = TestClient(TestServer(app))
        await self.client.start_server()
        self.addAsyncCleanup(self.client.close)

    async def test_export_list_download_delete_roundtrip(self):
        body = {"name": "Example", "prompt": {"1": {"class_type": "Example", "inputs": {"seed": 9007199254740993}}}}
        response = await self.client.post("/pocket/v1/workflows", json=body)
        self.assertEqual(response.status, 201)
        key = (await response.json())["id"]
        response = await self.client.get(f"/pocket/v1/workflows/{key}")
        self.assertEqual((await response.json())["prompt"], body["prompt"])
        listing = await (await self.client.get("/pocket/v1/workflows")).json()
        self.assertEqual(len(listing["workflows"]), 1)
        response = await self.client.delete(f"/pocket/v1/workflows/{key}")
        self.assertEqual(response.status, 200)
        self.assertEqual((await self.client.get(f"/pocket/v1/workflows/{key}")).status, 404)

    async def test_origin_content_type_and_shape_rejections(self):
        response = await self.client.post("/pocket/v1/workflows", json={}, headers={"Origin": "https://evil.example"})
        self.assertEqual(response.status, 403)
        self.assertEqual((await self.client.post("/pocket/v1/workflows", data="{}")).status, 415)
        self.assertEqual((await self.client.post("/pocket/v1/workflows", json=[])).status, 400)
        self.assertEqual((await self.client.get("/pocket/v1/workflows/..%2Foutside")).status, 400)

    async def test_users_have_separate_catalogs(self):
        body = {"name": "Private", "prompt": {"1": {"class_type": "Example", "inputs": {}}}}
        await self.client.post("/pocket/v1/workflows", json=body)
        response = await self.client.get("/pocket/v1/workflows", headers={"comfy-user": "second"})
        self.assertEqual((await response.json())["workflows"], [])
        response = await self.client.get("/pocket/v1/workflows", headers={"comfy-user": "unknown"})
        self.assertEqual(response.status, 403)

    async def test_streaming_body_limit(self):
        self.routes_module.MAX_BYTES = 20
        response = await self.client.post("/pocket/v1/workflows", data=b"x" * 30, headers={"Content-Type": "application/json"})
        self.assertEqual(response.status, 413)


if __name__ == "__main__":
    unittest.main()
