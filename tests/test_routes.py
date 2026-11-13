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

            def get_request_user_id(self, request):
                user = request.headers.get("comfy-user", "default")
                if user not in ("default", "second"):
                    raise KeyError(user)
                return user

        workflows = root / "default" / "workflows" / "nested"
        workflows.mkdir(parents=True)
        (workflows / "demo.json").write_text(json.dumps({"nodes": [], "links": []}), encoding="utf-8")

        previous_folder_paths = sys.modules.get("folder_paths")
        folder_paths = types.ModuleType("folder_paths")
        folder_paths.get_public_user_directory = lambda user: str(root / user)
        folder_paths.get_output_directory = lambda: str(root / "output")
        folder_paths.get_temp_directory = lambda: str(root / "temp")
        self.media_root = root / "output"
        self.media_root.mkdir()
        sys.modules["folder_paths"] = folder_paths

        def restore_folder_paths():
            if previous_folder_paths is not None:
                sys.modules["folder_paths"] = previous_folder_paths
            else:
                sys.modules.pop("folder_paths", None)

        self.addCleanup(restore_folder_paths)

        self.prompt_server = types.SimpleNamespace(routes=web.RouteTableDef(), user_manager=Users())
        previous = sys.modules.get("server")
        server = types.ModuleType("server")
        server.PromptServer = types.SimpleNamespace(instance=self.prompt_server)
        sys.modules["server"] = server
        self.addCleanup(lambda: sys.modules.__setitem__("server", previous) if previous else sys.modules.pop("server", None))
        package = types.ModuleType("pocket_test_plugin")
        package.__path__ = [str(ROOT / "server/comfyui_pocket")]
        sys.modules["pocket_test_plugin"] = package
        for part in ("catalog", "media", "routes"):
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

    async def test_media_delete_is_scoped_idempotent_and_requires_same_origin(self):
        target = self.media_root / "nested" / "a.png"
        target.parent.mkdir(); target.write_bytes(b"preview")
        body = {"filename": "a.png", "subfolder": "nested", "type": "output"}
        denied = await self.client.post("/pocket/v1/media/delete", json=body, headers={"Origin": "https://example.com"})
        self.assertEqual(denied.status, 403); self.assertTrue(target.exists())
        deleted = await self.client.post("/pocket/v1/media/delete", json=body)
        self.assertEqual(deleted.status, 200); self.assertFalse(target.exists())
        repeated = await self.client.post("/pocket/v1/media/delete", json=body)
        self.assertTrue((await repeated.json())["alreadyMissing"])

    async def test_media_delete_rejects_traversal_inputs_and_nonmedia_files(self):
        protected = self.media_root / "keep.json"; protected.write_text("{}")
        for body in [
            {"filename": "keep.json"}, {"filename": "../x.png"}, {"filename": "x.png", "subfolder": "../default"},
            {"filename": "x.png", "subfolder": "/tmp"}, {"filename": "x.png", "type": "input"},
            {"filename": "x.png", "subfolder": "C:\\output"}, {"filename": "x.png\x00"}, []
        ]:
            response = await self.client.post("/pocket/v1/media/delete", json=body)
            self.assertEqual(response.status, 400, body)
        self.assertTrue(protected.exists())

    async def test_export_list_download_delete_roundtrip(self):
        body = {"name": "Example", "prompt": {"1": {"class_type": "Example", "inputs": {"seed": 9007199254740993}}}}
        response = await self.client.post("/pocket/v1/workflows", json=body)
        self.assertEqual(response.status, 201)
        created = await response.json()
        self.assertIsInstance(created["updatedAt"], int)
        key = created["id"]
        response = await self.client.get(f"/pocket/v1/workflows/{key}")
        self.assertEqual((await response.json())["prompt"], body["prompt"])
        listing = await (await self.client.get("/pocket/v1/workflows")).json()
        self.assertEqual(len(listing["workflows"]), 1)
        self.assertEqual(listing["workflows"][0]["updatedAt"], created["updatedAt"])
        response = await self.client.delete(f"/pocket/v1/workflows/{key}")
        self.assertEqual(response.status, 200)
        self.assertEqual((await self.client.get(f"/pocket/v1/workflows/{key}")).status, 404)

    async def test_phone_update_keeps_ui_graph_and_advances_timestamp(self):
        body = {"name": "UI", "prompt": {"1": {"class_type": "Example", "inputs": {"value": 1}}},
                "workflow": {"nodes": [{"id": 1}]}}
        first = await (await self.client.post("/pocket/v1/workflows", json=body)).json()
        second = await (await self.client.post("/pocket/v1/workflows", json={
            "id": first["id"], "name": "Phone", "prompt": {"1": {"class_type": "Example", "inputs": {"value": 2}}}
        })).json()
        self.assertEqual(second["id"], first["id"])
        self.assertGreater(second["updatedAt"], first["updatedAt"])
        stored = await (await self.client.get(f"/pocket/v1/workflows/{first['id']}")).json()
        self.assertEqual(stored["name"], "Phone")
        self.assertEqual(stored["workflow"], {"nodes": [{"id": 1}]})

    async def test_comfy_workflows_are_listed_and_read(self):
        listing = await (await self.client.get("/pocket/v1/comfy-workflows")).json()
        self.assertEqual([item["path"] for item in listing["workflows"]], ["nested/demo.json"])
        item = listing["workflows"][0]
        self.assertIsInstance(item["modified"], int)
        response = await self.client.get("/pocket/v1/comfy-workflows/file", params={"path": item["path"]})
        self.assertEqual(response.status, 200)
        self.assertEqual((await response.json())["nodes"], [])
        self.assertEqual((await self.client.get("/pocket/v1/comfy-workflows/file",
                                                params={"path": "../outside.json"})).status, 400)
        self.assertEqual((await self.client.get("/pocket/v1/comfy-workflows/file",
                                                params={"path": "nested/missing.json"})).status, 404)

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
