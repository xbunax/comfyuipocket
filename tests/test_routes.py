import importlib.util
import json
import os
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
        folder_paths.get_user_directory = lambda: str(root)
        self.media_root = root / "output"
        self.media_root.mkdir()
        sys.modules["folder_paths"] = folder_paths

        def restore_folder_paths():
            if previous_folder_paths is not None:
                sys.modules["folder_paths"] = previous_folder_paths
            else:
                sys.modules.pop("folder_paths", None)

        self.addCleanup(restore_folder_paths)

        self.prompt_server = types.SimpleNamespace(routes=web.RouteTableDef(), user_manager=Users(), app=web.Application())
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
        app = self.prompt_server.app
        app.add_routes(self.prompt_server.routes)
        self.client = TestClient(TestServer(app))
        await self.client.start_server()
        self.addAsyncCleanup(self.client.close)

    async def test_output_browser_folders_paging_and_media_without_history(self):
        (self.media_root / "相册").mkdir()
        (self.media_root / "empty").mkdir()
        (self.media_root / "old.png").write_bytes(b"old")
        (self.media_root / "new.mp4").write_bytes(b"video")
        (self.media_root / "keep.json").write_text("{}")
        (self.media_root / "相册" / "图 1.PNG").write_bytes(b"image")
        os.utime(self.media_root / "old.png", (100, 100))
        os.utime(self.media_root / "new.mp4", (200, 200))
        response = await self.client.get("/pocket/v1/outputs", params={"limit": "2"})
        self.assertEqual(response.status, 200)
        first = await response.json()
        self.assertEqual(first["folder"], "")
        self.assertEqual(first["total"], 4)
        self.assertEqual([item["kind"] for item in first["entries"]], ["folder", "folder"])
        self.assertEqual(first["nextOffset"], 2)
        second = await (await self.client.get("/pocket/v1/outputs", params={"offset": "2", "limit": "2"})).json()
        self.assertEqual([item["name"] for item in second["entries"]], ["new.mp4", "old.png"])
        self.assertIsNone(second["nextOffset"])
        nested = await (await self.client.get("/pocket/v1/outputs", params={"folder": "相册"})).json()
        self.assertEqual(nested["entries"][0]["path"], "相册/图 1.PNG")

        self.assertEqual(nested["entries"][0]["subfolder"], "相册")
        self.assertEqual(nested["entries"][0]["size"], 5)
        empty = await (await self.client.get("/pocket/v1/outputs", params={"folder": "empty"})).json()
        self.assertEqual(empty["total"], 0)
        self.assertEqual(empty["entries"], [])
        info = await (await self.client.get("/pocket/v1/info")).json()
        self.assertIn("output-browser", info["capabilities"])

    async def test_pairing_is_opt_in_and_control_routes_reject_foreign_origins(self):
        status = await (await self.client.get("/pocket/v1/pairing")).json()
        self.assertFalse(status["enabled"])
        self.assertTrue(status["directOnly"])
        self.assertEqual(status["peers"], [])
        for action in ("invite", "stop", "revoke"):
            response = await self.client.post("/pocket/v1/pairing/" + action,
                json={}, headers={"Origin": "https://other.example"})
            self.assertEqual(response.status, 403)
        self.assertEqual((await self.client.post("/pocket/v1/pairing/revoke", json={"id": "invalid"})).status, 400)
        self.assertEqual((await self.client.post("/pocket/v1/pairing/stop", json={})).status, 200)
        import folder_paths
        self.assertFalse((pathlib.Path(folder_paths.get_user_directory()) / "pocket-pairing").exists())

    async def test_output_browser_rejects_invalid_paths_pages_and_unknown_users(self):
        for folder in ("../", "/", "a/../../", "C:/", "a\\b", "a/./b", "\x00"):
            response = await self.client.get("/pocket/v1/outputs", params={"folder": folder})
            self.assertEqual(response.status, 400, folder)
        for query in ({"offset": "-1"}, {"offset": "bad"}, {"limit": "0"}, {"limit": "101"}):
            self.assertEqual((await self.client.get("/pocket/v1/outputs", params=query)).status, 400)
        self.assertEqual((await self.client.get("/pocket/v1/outputs", params={"folder": "missing"})).status, 404)
        self.assertEqual((await self.client.get("/pocket/v1/outputs", headers={"comfy-user": "unknown"})).status, 403)

    async def test_output_sort_is_global_before_paging_and_reversible(self):
        (self.media_root / "folder").mkdir()
        for name, size, modified in [("b.png", 2, 10), ("a.png", 5, 30), ("c.mp4", 1, 20)]:
            (self.media_root / name).write_bytes(b"x" * size)
            os.utime(self.media_root / name, (modified, modified))
        for sort, expected in [("name", ["a.png", "b.png", "c.mp4"]),
                               ("size", ["c.mp4", "b.png", "a.png"]),
                               ("time", ["b.png", "c.mp4", "a.png"])]:
            for direction in ("ascending", "descending"):
                names = []
                for offset in range(4):
                    response = await self.client.get("/pocket/v1/outputs", params={
                        "sort": sort, "direction": direction, "offset": str(offset), "limit": "1"})
                    self.assertEqual(response.status, 200)
                    names.extend(item["name"] for item in (await response.json())["entries"])
                self.assertEqual(names, ["folder"] + (expected if direction == "ascending" else list(reversed(expected))))
        for query in ({"sort": "invalid"}, {"direction": "invalid"}):
            self.assertEqual((await self.client.get("/pocket/v1/outputs", params=query)).status, 400)
        self.assertIn("output-sort", (await (await self.client.get("/pocket/v1/info")).json())["capabilities"])

    async def test_output_browser_does_not_follow_links(self):
        outside = pathlib.Path(self.temp.name) / "outside"
        outside.mkdir(); (outside / "private.png").write_bytes(b"private")
        try:
            (self.media_root / "linked").symlink_to(outside, target_is_directory=True)
            (self.media_root / "linked.png").symlink_to(outside / "private.png")
        except OSError:
            self.skipTest("Creating symbolic links is not permitted on this host")
        page = await (await self.client.get("/pocket/v1/outputs")).json()
        self.assertEqual(page["entries"], [])
        response = await self.client.get("/pocket/v1/outputs", params={"folder": "linked"})
        self.assertEqual(response.status, 400)

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
