"""Exercise an isolated local ComfyUI instance with a 32x32 image, no model/GPU.

Run only against a disposable server/user directory. This creates a tiny output
and uploads it back to input as part of API verification.
"""
import argparse
import asyncio
import json
import uuid

import aiohttp


async def main(base):
    client_id = str(uuid.uuid4())
    prompt = {
        "1": {"class_type": "EmptyImage", "inputs": {"width": 32, "height": 32, "batch_size": 1, "color": 6807720}},
        "2": {"class_type": "SaveImage", "inputs": {"images": ["1", 0], "filename_prefix": "PocketSmoke"}},
    }
    async with aiohttp.ClientSession(timeout=aiohttp.ClientTimeout(total=30)) as session:
        async def request(path, method="GET", **kwargs):
            async with session.request(method, base + path, **kwargs) as response:
                response.raise_for_status()
                return await response.json()

        info = await request("/pocket/v1/info")
        exported = await request("/pocket/v1/workflows", "POST", json={"name": "Pocket smoke test", "prompt": prompt})
        key = exported["id"]
        try:
            loaded = await request(f"/pocket/v1/workflows/{key}")
            assert loaded["prompt"] == prompt
            events = []
            async with session.ws_connect(base + "/ws", params={"clientId": client_id}) as ws:
                reply = await request("/prompt", "POST", json={"prompt": prompt, "client_id": client_id})
                prompt_id = reply["prompt_id"]
                async with asyncio.timeout(30):
                    async for message in ws:
                        if message.type != aiohttp.WSMsgType.TEXT:
                            continue
                        event = json.loads(message.data)
                        events.append(event["type"])
                        if event["type"] == "execution_error":
                            raise RuntimeError(event["data"])
                        if event["type"] == "executing" and event["data"].get("prompt_id") == prompt_id and event["data"].get("node") is None:
                            break
            history = await request(f"/history/{prompt_id}")
            image = history[prompt_id]["outputs"]["2"]["images"][0]
            async with session.get(base + "/view", params={key: image[key] for key in ("filename", "subfolder", "type")}) as response:
                response.raise_for_status()
                data = await response.read()
                assert data.startswith(b"\x89PNG")
            form = aiohttp.FormData()
            form.add_field("image", data, filename="pocket-smoke.png", content_type="image/png")
            form.add_field("type", "input")
            uploaded = await request("/upload/image", "POST", data=form)
            assert uploaded["name"]
            print(json.dumps({"plugin": info["version"], "catalog_roundtrip": True, "prompt_completed": True,
                              "websocket_events": sorted(set(events)), "image_download_bytes": len(data), "upload": True}))
        finally:
            await request(f"/pocket/v1/workflows/{key}", "DELETE")


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--base-url", default="http://127.0.0.1:8199")
    args = parser.parse_args()
    asyncio.run(main(args.base_url.rstrip("/")))
