import asyncio
import base64
import contextlib
import importlib.util
import io
import json
import logging
from pathlib import Path
import ssl

from aiohttp import web

from .pairing import PairingServer


def register_pairing_routes(server, catalog_for, same_origin, read_json):
    service = None
    startup_task = None

    def identity_path():
        import folder_paths
        return Path(folder_paths.get_user_directory()) / "pocket-pairing" / "identity.json"

    def current_service():
        nonlocal service
        if service is None:
            if importlib.util.find_spec("iroh") is None:
                raise web.HTTPServiceUnavailable(text="请安装 Pocket 插件 requirements.txt 中的 iroh 依赖后重试。")
            from comfy.cli_args import args
            context = None
            if args.tls_keyfile and args.tls_certfile:
                context = ssl.create_default_context(cafile=args.tls_certfile)
                # Only the fixed loopback ComfyUI socket is dialed. Trust its own
                # configured certificate; its hostname may be a public DNS name.
                context.check_hostname = False
            service = PairingServer(identity_path(), server.port, context)
        return service

    def status():
        result = service.status() if service else {"enabled": False, "directOnly": True, "peers": []}
        result["available"] = importlib.util.find_spec("iroh") is not None
        return result

    @server.routes.get("/pocket/v1/pairing")
    async def pairing_status(request):
        catalog_for(request)
        return web.json_response(status())

    @server.routes.post("/pocket/v1/pairing/invite")
    async def pairing_invite(request):
        same_origin(request); catalog_for(request); await read_json(request)
        try:
            result = await current_service().create_invite()
            def qr_image():
                import qrcode
                image = qrcode.make(result["code"])
                output = io.BytesIO(); image.save(output, format="PNG")
                return base64.b64encode(output.getvalue()).decode()
            try: result["qrPng"] = await asyncio.to_thread(qr_image)
            except ModuleNotFoundError: result["qrPng"] = None
            return web.json_response(result, headers={"Cache-Control": "no-store"})
        except web.HTTPException: raise
        except (ValueError, OSError, AttributeError) as error:
            raise web.HTTPBadRequest(text="无法创建直连配对，请检查依赖和电脑网络。") from error

    @server.routes.post("/pocket/v1/pairing/stop")
    async def pairing_stop(request):
        same_origin(request); catalog_for(request); await read_json(request)
        if service: await service.stop()
        return web.json_response(status())

    @server.routes.post("/pocket/v1/pairing/revoke")
    async def pairing_revoke(request):
        same_origin(request); catalog_for(request); body = await read_json(request)
        peer = body.get("id") if isinstance(body, dict) else None
        if not isinstance(peer, str) or len(peer) != 64 or any(c not in "0123456789abcdef" for c in peer):
            raise web.HTTPBadRequest(text="Invalid peer id")
        if service: await service.revoke(peer)
        return web.json_response(status())

    async def resume_saved():
        try:
            path = identity_path()
            if not path.exists() or not json.loads(path.read_text(encoding="utf-8")).get("enabled", False): return
            # PromptServer sets port after aiohttp's startup hooks have finished.
            for _ in range(200):
                if hasattr(server, "port"):
                    await current_service().start(); return
                await asyncio.sleep(0.1)
            logging.warning("Pocket P2P 未启动：ComfyUI 端口尚未就绪。")
        except Exception:
            logging.warning("Pocket P2P 未启动：请检查插件依赖和已保存的配对身份。IP 连接仍可使用。")

    async def startup(app):
        nonlocal startup_task
        startup_task = asyncio.create_task(resume_saved())

    async def cleanup(app):
        if startup_task:
            startup_task.cancel()
            with contextlib.suppress(asyncio.CancelledError): await startup_task
        if service: await service.stop(disable=False)

    server.app.on_startup.append(startup)
    server.app.on_cleanup.append(cleanup)
