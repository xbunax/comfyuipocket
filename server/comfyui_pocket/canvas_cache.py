"""Conditional responses for Pocket's embedded ComfyUI editor."""

import asyncio
import hashlib
import json
import os
import tempfile
from collections import OrderedDict
from contextlib import suppress

from aiohttp import web


REVISION = "X-Pocket-Node-Revision"
DELTA = "X-Pocket-Node-Delta"
CANVAS_AGENT = "ComfyUIPocketCanvas"
MAX_SNAPSHOT_BYTES = 16 * 1024 * 1024


def node_delta(before, after):
    old, new = json.loads(before), json.loads(after)
    # JSON numbers and booleans can compare equal in Python while representing
    # different control types. Compare their JSON encodings.
    changed = {name: value for name, value in new.items()
               if name not in old or json.dumps(old[name]) != json.dumps(value)}
    return json.dumps({
        "changed": changed,
        "removed": [name for name in old if name not in new],
    }, separators=(",", ":")).encode()


def read_snapshot(path):
    try:
        with path.open("rb") as stream:
            data = stream.read(MAX_SNAPSHOT_BYTES + 1)
        return data if len(data) <= MAX_SNAPSHOT_BYTES else None
    except OSError:
        return None


def save_snapshot(path, data):
    temporary = None
    try:
        path.parent.mkdir(parents=True, exist_ok=True)
        with tempfile.NamedTemporaryFile(dir=path.parent, delete=False) as stream:
            temporary = stream.name
            stream.write(data)
        os.replace(temporary, path)
    except OSError:
        pass
    finally:
        if temporary:
            with suppress(OSError):
                os.unlink(temporary)


def canvas_cache(snapshot_path=None):
    snapshots = OrderedDict()
    lock = asyncio.Lock()

    @web.middleware
    async def middleware(request, handler):
        response = await handler(request)
        path = request.path.removeprefix("/api/")
        if path.lstrip("/") == "object_info" and request.method == "GET":
            response.headers.add("Vary", REVISION)
            baseline = request.headers.get(REVISION)
            if (baseline is None or response.status != 200 or not isinstance(response.body, bytes)
                    or request.headers.get("Comfy-User", "") not in ("", "default")
                    or "Authorization" in request.headers or "Cookie" in request.headers):
                return response

            body = response.body
            revision = hashlib.sha256(body).hexdigest()
            headers = response.headers.copy()
            headers[REVISION] = revision
            headers["Cache-Control"] = "private, no-store"

            async with lock:
                if not snapshots and snapshot_path is not None:
                    saved = await asyncio.to_thread(read_snapshot, snapshot_path)
                    if saved is not None:
                        snapshots[hashlib.sha256(saved).hexdigest()] = saved
                previous = snapshots.get(baseline)
                if revision != next(reversed(snapshots), None) and len(body) <= MAX_SNAPSHOT_BYTES:
                    snapshots[revision] = body
                    snapshots.move_to_end(revision)
                    while len(snapshots) > 3:
                        snapshots.popitem(last=False)
                    if snapshot_path is not None:
                        await asyncio.to_thread(save_snapshot, snapshot_path, body)

            if baseline == revision:
                return web.Response(status=304, headers=headers)
            if previous is not None:
                delta = await asyncio.to_thread(node_delta, previous, body)
                if len(delta) < len(body):
                    body = delta
                    headers[DELTA] = "1"
            headers.pop("Content-Length", None)
            result = web.Response(body=body, headers=headers, zlib_executor_size=256 * 1024)
            result.enable_compression()
            return result

        if (request.method in ("GET", "HEAD") and isinstance(response, web.FileResponse)
                and request.path.startswith(("/assets/", "/scripts/", "/extensions/"))
                and request.path.endswith((".js", ".mjs", ".css"))):
            response.headers.add("Vary", "User-Agent")
            if CANVAS_AGENT in request.headers.get("User-Agent", "").split():
                # FileResponse supplies ETag and Last-Modified and handles 304.
                response.headers["Cache-Control"] = "private, no-cache"
        return response

    return middleware
