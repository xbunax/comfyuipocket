import asyncio
import base64
import hashlib
import importlib.util
import io
import json
import pathlib
import socket
import sys
import tempfile
import unittest
from unittest.mock import patch
from urllib.parse import parse_qs, urlsplit

from aiohttp import ClientSession, web

try:
    import iroh
except ImportError:
    iroh = None

spec = importlib.util.spec_from_file_location("pocket_pairing", pathlib.Path(__file__).resolve().parents[1] / "server/comfyui_pocket/pairing.py")
pairing = importlib.util.module_from_spec(spec)
spec.loader.exec_module(pairing)


@unittest.skipUnless(iroh, "Install optional iroh bindings to run direct transport tests")
class PairingTests(unittest.IsolatedAsyncioTestCase):
    async def asyncSetUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.preset = patch.object(iroh, "preset_n0_disable_relay", iroh.preset_minimal)
        self.preset.start(); self.addCleanup(self.preset.stop)
        iroh.iroh_ffi.uniffi_set_event_loop(asyncio.get_running_loop())
        self.payload = bytes(range(256)) * 8192
        app = web.Application()
        async def stats(request): return web.json_response({"device": "test"})
        app.router.add_get("/stats", stats)
        async def upload(request):
            digest = hashlib.sha256(); size = 0
            async for data in request.content.iter_chunked(65536): digest.update(data); size += len(data)
            return web.json_response({"bytes": size, "sha256": digest.hexdigest()})
        async def socket(request):
            ws = web.WebSocketResponse(); await ws.prepare(request)
            async for message in ws:
                if message.type == web.WSMsgType.TEXT: await ws.send_str(message.data)
                elif message.type == web.WSMsgType.BINARY: await ws.send_bytes(message.data)
            return ws
        file = pathlib.Path(self.temp.name) / "media.bin"; file.write_bytes(self.payload)
        async def media(request): return web.FileResponse(file)
        app.router.add_get("/media", media)
        app.router.add_post("/upload", upload); app.router.add_get("/ws", socket)
        self.runner = web.AppRunner(app); await self.runner.setup()
        site = web.TCPSite(self.runner, "127.0.0.1", 0); await site.start()
        port = site._server.sockets[0].getsockname()[1]
        self.service = pairing.PairingServer(pathlib.Path(self.temp.name) / "identity.json", port)
        invite = await self.service.create_invite()
        data = parse_qs(urlsplit(invite["code"]).query)["d"][0]
        self.invite = json.loads(base64.urlsafe_b64decode(data + "=" * (-len(data) % 4)))
        self.client = await iroh.Endpoint.bind(iroh.EndpointOptions(preset=iroh.preset_minimal(), relay_mode=iroh.RelayMode.disabled()))
        self.connection = None; self.proxy = None; self.proxies = set()

    async def asyncTearDown(self):
        if self.proxy: self.proxy.close(); await self.proxy.wait_closed()
        for task in list(self.proxies): task.cancel()
        if self.proxies: await asyncio.gather(*list(self.proxies), return_exceptions=True)
        await self.client.close(); await self.service.stop(); await self.runner.cleanup()

    async def authenticate(self, token):
        address = iroh.EndpointTicket.from_string(self.invite["ticket"]).endpoint_addr()
        connection = await asyncio.wait_for(self.client.connect(address, pairing.ALPN), 5)
        stream = await connection.open_bi()
        await pairing.write_frame(stream.send(), {"v": 1, "token": token})
        await stream.send().finish()
        response = await asyncio.wait_for(pairing.read_frame(stream.recv()), 5)
        self.assertTrue(response["ok"]); self.assertTrue(response["directOnly"])
        self.assertEqual(response["endpointId"], str(connection.remote_id()))
        self.assertTrue(any(p.is_selected and p.is_ip for p in connection.paths()))
        self.assertFalse(any(p.is_relay for p in connection.paths()))
        return connection

    async def start_proxy(self):
        self.connection = await self.authenticate(self.invite["token"])
        async def handle(reader, writer):
            task = asyncio.current_task(); self.proxies.add(task)
            try:
                stream = await self.connection.open_bi()
                async def up():
                    while data := await reader.read(65536): await stream.send().write_all(data)
                    await stream.send().finish()
                async def down():
                    while data := await stream.recv().read(65536): writer.write(data); await writer.drain()
                    if writer.can_write_eof(): writer.write_eof()
                pumps = [asyncio.create_task(up()), asyncio.create_task(down())]
                try: await asyncio.gather(*pumps)
                finally:
                    for pump in pumps: pump.cancel()
                    await asyncio.gather(*pumps, return_exceptions=True)
            except (Exception, asyncio.CancelledError): pass
            finally:
                writer.close(); self.proxies.discard(task)
        self.proxy = await asyncio.start_server(handle, "127.0.0.1", 0)
        return "http://127.0.0.1:" + str(self.proxy.sockets[0].getsockname()[1])

    async def test_http_websocket_media_ranges_and_upload_over_direct_quic(self):
        url = await self.start_proxy()
        async with ClientSession() as client:
            async with client.get(url + "/stats") as response:
                self.assertEqual(await response.json(), {"device": "test"})
            async with client.head(url + "/media") as response:
                self.assertEqual(response.content_length, len(self.payload))
            async with client.get(url + "/media", headers={"Range": "bytes=123-456"}) as response:
                self.assertEqual(response.status, 206); self.assertEqual(await response.read(), self.payload[123:457])
            async with client.get(url + "/media") as response:
                self.assertEqual(hashlib.sha256(await response.read()).digest(), hashlib.sha256(self.payload).digest())
            async with client.post(url + "/upload", data=io.BytesIO(self.payload)) as response:
                self.assertEqual(await response.json(), {"bytes": len(self.payload), "sha256": hashlib.sha256(self.payload).hexdigest()})
            async with client.ws_connect(url + "/ws") as ws:
                await ws.send_str("queue-event"); self.assertEqual((await ws.receive()).data, "queue-event")
                await ws.send_bytes(self.payload[:8192]); self.assertEqual((await ws.receive()).data, self.payload[:8192])

    async def test_invalid_expired_token_and_consumed_invite_are_rejected(self):
        with self.assertRaises(Exception): await self.authenticate("incorrect")
        self.service.invite = (self.invite["token"], 0)
        with self.assertRaises(Exception): await self.authenticate(self.invite["token"])
        self.service.invite = (self.invite["token"], self.invite["expiresAt"])
        await self.authenticate(self.invite["token"])
        self.assertIsNone(self.service.invite)
        await self.authenticate(None)  # Reconnect proves possession of the approved peer's private key.
        await self.service.revoke(str(self.client.id()))
        with self.assertRaises(Exception): await self.authenticate(None)

    async def test_identity_and_approved_peers_survive_restart(self):
        await self.authenticate(self.invite["token"])
        identity = str(self.service.endpoint.id())
        ports = dict(self.service.udp_ports)
        await self.service.stop(disable=False)
        self.service = pairing.PairingServer(self.service.path, self.service.port)
        await self.service.start()
        self.assertEqual(str(self.service.endpoint.id()), identity)
        self.assertIn(str(self.client.id()), self.service.peers)
        self.assertEqual(self.service.udp_ports, ports)
        # Use the original ticket and no token. Both endpoints have discovery
        # disabled in the fixture, so this requires the saved UDP sockets.
        await self.authenticate(None)

    async def test_legacy_identity_acquires_ports_without_losing_authorization(self):
        await self.authenticate(self.invite["token"])
        identity = str(self.service.endpoint.id())
        await self.service.stop(disable=False)
        saved = json.loads(self.service.path.read_text(encoding="utf-8"))
        saved.pop("udpPorts")
        self.service.path.write_text(json.dumps(saved), encoding="utf-8")
        self.service = pairing.PairingServer(self.service.path, self.service.port)
        await self.service.start()
        self.assertEqual(str(self.service.endpoint.id()), identity)
        self.assertIn(str(self.client.id()), self.service.peers)
        self.assertTrue(self.service.udp_ports)
        self.assertEqual(json.loads(self.service.path.read_text())["udpPorts"], self.service.udp_ports)

    async def test_port_conflict_preserves_other_family_and_saved_peer(self):
        await self.authenticate(self.invite["token"])
        ports = dict(self.service.udp_ports)
        await self.service.stop(disable=False)
        with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as occupied:
            occupied.bind(("0.0.0.0", ports["ipv4"]))
            self.service = pairing.PairingServer(self.service.path, self.service.port)
            with self.assertLogs("pocket_pairing", level="INFO") as logs:
                await self.service.start()
            self.assertNotEqual(self.service.udp_ports["ipv4"], ports["ipv4"])
            if "ipv6" in ports:
                self.assertEqual(self.service.udp_ports["ipv6"], ports["ipv6"])
            self.assertIn(str(self.client.id()), self.service.peers)
            self.assertNotIn(self.invite["token"], "\n".join(logs.output))


if __name__ == "__main__": unittest.main()
