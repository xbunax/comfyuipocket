import asyncio
import json
from pathlib import Path
from urllib.parse import urlsplit

from aiohttp import web
from server import PromptServer

from .catalog import Catalog, MAX_BYTES, VERSION


def same_origin(request):
    origin = request.headers.get("Origin")
    if origin:
        parsed = urlsplit(origin)
        if parsed.netloc != request.host or parsed.scheme not in ("http", "https"):
            raise web.HTTPForbidden(text="Cross-origin writes are not allowed")


def catalog_for(request):
    manager = PromptServer.instance.user_manager
    try:
        path = manager.get_request_user_filepath(request, "pocket/catalog/.anchor")
    except KeyError as exc:
        raise web.HTTPForbidden(text="Unknown ComfyUI user") from exc
    if path is None:
        raise web.HTTPForbidden(text="User storage is unavailable")
    return Catalog(Path(path).parent)


def workflows_root(request):
    import folder_paths

    manager = PromptServer.instance.user_manager
    try:
        user = manager.get_request_user_id(request)
    except KeyError as exc:
        raise web.HTTPForbidden(text="Unknown ComfyUI user") from exc
    root = folder_paths.get_public_user_directory(user)
    if root is None:
        raise web.HTTPForbidden(text="User storage is unavailable")
    return (Path(root) / "workflows").resolve()


async def read_json(request):
    if request.content_type != "application/json":
        raise web.HTTPUnsupportedMediaType(text="Expected application/json")
    data = bytearray()
    async for chunk in request.content.iter_chunked(65536):
        data.extend(chunk)
        if len(data) > MAX_BYTES:
            raise web.HTTPRequestEntityTooLarge(max_size=MAX_BYTES, actual_size=len(data))
    try:
        return json.loads(data)
    except (ValueError, UnicodeDecodeError) as exc:
        raise web.HTTPBadRequest(text="Invalid JSON") from exc


def register_routes():
    routes = PromptServer.instance.routes

    @routes.get("/pocket/v1/info")
    async def info(request):
        return web.json_response({"version": VERSION, "protocol": 1, "transport": "direct",
                                  "capabilities": ["catalog", "api-prompt", "frontend-export", "auto-sync"]})

    @routes.get("/pocket/v1/comfy-workflows")
    async def comfy_workflows(request):
        root = workflows_root(request)
        items = []
        if root.is_dir():
            for path in sorted(root.rglob("*.json")):
                try:
                    resolved = path.resolve()
                    if root not in resolved.parents or not resolved.is_file():
                        continue
                    stat = resolved.stat()
                    items.append({"path": resolved.relative_to(root).as_posix(), "name": path.stem,
                                  "modified": int(stat.st_mtime * 1000), "size": stat.st_size})
                except (OSError, ValueError):
                    continue
        return web.json_response({"workflows": items})

    @routes.get("/pocket/v1/comfy-workflows/file")
    async def comfy_workflow_file(request):
        rel_path = request.rel_url.query.get("path", "")
        if not rel_path or "\\" in rel_path or "\x00" in rel_path:
            raise web.HTTPBadRequest(text="Invalid workflow path")
        root = workflows_root(request)
        candidate = (root / rel_path).resolve()
        if root not in candidate.parents or candidate.suffix.lower() != ".json":
            raise web.HTTPBadRequest(text="Invalid workflow path")
        if not candidate.is_file():
            raise web.HTTPNotFound(text="Workflow not found")
        if candidate.stat().st_size > MAX_BYTES:
            raise web.HTTPRequestEntityTooLarge(max_size=MAX_BYTES, actual_size=candidate.stat().st_size)
        return web.Response(body=candidate.read_bytes(), content_type="application/json")

    @routes.get("/pocket/v1/workflows")
    async def workflows(request):
        catalog = catalog_for(request)
        return web.json_response({"workflows": await asyncio.to_thread(catalog.list)})

    @routes.get("/pocket/v1/workflows/{workflow_id}")
    async def workflow(request):
        try:
            data = await asyncio.to_thread(catalog_for(request).get, request.match_info["workflow_id"])
            return web.json_response(data)
        except FileNotFoundError as exc:
            raise web.HTTPNotFound(text="Workflow not found") from exc
        except ValueError as exc:
            raise web.HTTPBadRequest(text=str(exc)) from exc

    @routes.post("/pocket/v1/workflows")
    async def save(request):
        same_origin(request)
        data = await read_json(request)
        try:
            value = await asyncio.to_thread(catalog_for(request).save, data)
            return web.json_response({"id": value["id"], "name": value["name"],
                                      "updatedAt": value["updatedAt"]}, status=201)
        except ValueError as exc:
            raise web.HTTPBadRequest(text=str(exc)) from exc

    @routes.delete("/pocket/v1/workflows/{workflow_id}")
    async def delete(request):
        same_origin(request)
        try:
            await asyncio.to_thread(catalog_for(request).delete, request.match_info["workflow_id"])
        except FileNotFoundError as exc:
            raise web.HTTPNotFound(text="Workflow not found") from exc
        except ValueError as exc:
            raise web.HTTPBadRequest(text=str(exc)) from exc
        return web.json_response({"deleted": True})
