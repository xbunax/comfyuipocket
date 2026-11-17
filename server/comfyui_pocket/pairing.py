"""Opt-in iroh endpoint. Relays are disabled for the endpoint's entire lifetime."""

import asyncio
import base64
import contextlib
import hmac
import importlib
import json
import os
import secrets
import struct
import tempfile
import time
from pathlib import Path

ALPN = b"comfyuipocket/tcp/1"
MAX_FRAME = 8192


async def read_frame(stream):
    length = struct.unpack("!I", await stream.read_exact(4))[0]
    if not 1 <= length <= MAX_FRAME:
        raise ValueError("Invalid pairing frame")
    value = json.loads(await stream.read_exact(length))
    if not isinstance(value, dict):
        raise ValueError("Expected a pairing object")
    return value


async def write_frame(stream, value):
    data = json.dumps(value, separators=(",", ":")).encode()
    if len(data) > MAX_FRAME:
        raise ValueError("Pairing frame too large")
    await stream.write_all(struct.pack("!I", len(data)) + data)


class PairingServer:
    def __init__(self, identity_path, port, ssl_context=None):
        self.path = Path(identity_path)
        self.port = port
        self.ssl_context = ssl_context
        self.endpoint = None
        self.accept_task = None
        self.connections = {}
        self.tasks = set()
        self.invite = None
        self.lock = asyncio.Lock()
        self.peers = set()
        self.secret = None
        self.enabled = False

    def _read_identity(self):
        if not self.path.exists():
            return secrets.token_bytes(32), set()
        data = json.loads(self.path.read_text(encoding="utf-8"))
        secret = base64.b64decode(data["secret"], validate=True)
        peers = data.get("peers", [])
        if len(secret) != 32 or not isinstance(peers, list) or any(
                not isinstance(p, str) or len(p) != 64 or any(c not in "0123456789abcdef" for c in p) for p in peers):
            raise ValueError("Invalid saved pairing identity")
        return secret, set(peers)

    def _save_identity(self):
        self.path.parent.mkdir(parents=True, exist_ok=True)
        data = {"version": 1, "secret": base64.b64encode(self.secret).decode(), "peers": sorted(self.peers), "enabled": self.enabled}
        name = None
        try:
            with tempfile.NamedTemporaryFile(mode="w", encoding="utf-8", dir=self.path.parent, delete=False) as file:
                name = file.name
                json.dump(data, file, separators=(",", ":"))
                file.flush(); os.fsync(file.fileno())
            os.replace(name, self.path)
        finally:
            if name and os.path.exists(name):
                os.unlink(name)

    async def start(self):
        async with self.lock:
            if self.endpoint is not None:
                return
            iroh = importlib.import_module("iroh")
            iroh.iroh_ffi.uniffi_set_event_loop(asyncio.get_running_loop())
            self.secret, self.peers = await asyncio.to_thread(self._read_identity)
            endpoint = await iroh.Endpoint.bind(iroh.EndpointOptions(
                preset=iroh.preset_n0_disable_relay(), relay_mode=iroh.RelayMode.disabled(),
                secret_key=self.secret, alpns=[ALPN]))
            self.enabled = True
            try:
                await asyncio.to_thread(self._save_identity)
            except BaseException:
                await endpoint.close()
                raise
            self.iroh = iroh
            self.endpoint = endpoint
            self.accept_task = asyncio.create_task(self._accept())

    def status(self):
        return {"enabled": self.endpoint is not None, "directOnly": True,
                "endpointId": str(self.endpoint.id()) if self.endpoint else None,
                "peers": [{"id": p, "connected": p in self.connections} for p in sorted(self.peers)]}

    async def create_invite(self):
        await self.start()
        # online() waits for a relay and must never be called in direct-only mode.
        deadline = time.monotonic() + 3
        while not self.endpoint.addr().direct_addresses() and time.monotonic() < deadline:
            await asyncio.sleep(0.1)
        address = self.endpoint.addr()
        if address.relay_url() is not None or not address.direct_addresses():
            raise ValueError("No usable direct address; check the computer network")
        token = secrets.token_urlsafe(32)
        expires = int(time.time()) + 300
        self.invite = (token, expires)
        payload = {"v": 1, "ticket": str(self.iroh.EndpointTicket.from_addr(address)),
                   "endpointId": str(self.endpoint.id()), "name": "ComfyUI", "token": token,
                   "expiresAt": expires, "directOnly": True}
        encoded = base64.urlsafe_b64encode(json.dumps(payload, separators=(",", ":")).encode()).decode().rstrip("=")
        return {"code": "comfypocket://iroh/1?d=" + encoded, "expiresAt": expires, "directOnly": True}

    def _spawn(self, coroutine):
        task = asyncio.create_task(coroutine)
        self.tasks.add(task)
        task.add_done_callback(self.tasks.discard)
        return task

    async def _accept(self):
        try:
            while self.endpoint is not None:
                incoming = await self.endpoint.accept_next()
                if incoming is None:
                    return
                if len(self.tasks) >= 128:
                    incoming.refuse()
                else:
                    self._spawn(self._connection(incoming))
        except asyncio.CancelledError:
            return

    async def _connection(self, incoming):
        connection = None
        peer = None
        streams = set()
        try:
            accepting = await incoming.accept()
            connection = await asyncio.wait_for(accepting.connect(), 10)
            peer = str(connection.remote_id())
            if any(p.is_relay for p in connection.paths()):
                raise ValueError("Relay path is forbidden")
            first = await asyncio.wait_for(connection.accept_bi(), 10)
            hello = await asyncio.wait_for(read_frame(first.recv()), 10)
            if hello.get("v") != 1: raise ValueError("Unsupported pairing version")
            async with self.lock:
                if peer not in self.peers:
                    token = hello.get("token")
                    if not (hello.get("v") == 1 and self.invite and self.invite[1] >= time.time()
                            and isinstance(token, str) and token.isascii()
                            and hmac.compare_digest(token, self.invite[0])):
                        raise ValueError("Pairing code is expired, used or invalid")
                    self.peers.add(peer)
                    try:
                        await asyncio.to_thread(self._save_identity)
                    except BaseException:
                        self.peers.discard(peer)
                        raise
                    self.invite = None
                old = self.connections.get(peer)
                if old is not None:
                    old.close(0, b"reconnected")
                self.connections[peer] = connection
            await write_frame(first.send(), {"ok": True, "v": 1, "directOnly": True,
                "endpointId": str(self.endpoint.id()), "name": "ComfyUI",
                "ticket": str(self.iroh.EndpointTicket.from_addr(self.endpoint.addr()))})
            await first.send().finish()
            connection.set_max_concurrent_bi_streams(64)
            while True:
                stream = await connection.accept_bi()
                task = self._spawn(self._forward(stream))
                streams.add(task); task.add_done_callback(streams.discard)
        except (Exception, asyncio.CancelledError):
            pass  # The dial side receives a closed connection; never log pairing secrets.
        finally:
            for task in list(streams): task.cancel()
            if streams: await asyncio.gather(*list(streams), return_exceptions=True)
            if peer is not None and self.connections.get(peer) is connection:
                self.connections.pop(peer, None)
            if connection is not None: connection.close(0, b"pairing session closed")

    async def _forward(self, stream):
        writer = None
        try:
            reader, writer = await asyncio.wait_for(asyncio.open_connection(
                "127.0.0.1", self.port, ssl=self.ssl_context,
                server_hostname="localhost" if self.ssl_context else None), 5)
            async def to_tcp():
                while data := await stream.recv().read(65536):
                    writer.write(data); await writer.drain()
                if writer.can_write_eof(): writer.write_eof()
            async def from_tcp():
                while data := await reader.read(65536): await stream.send().write_all(data)
                await stream.send().finish()
            tasks = [asyncio.create_task(to_tcp()), asyncio.create_task(from_tcp())]
            try:
                await asyncio.gather(*tasks)
            finally:
                for task in tasks: task.cancel()
                await asyncio.gather(*tasks, return_exceptions=True)
        except (Exception, asyncio.CancelledError):
            with contextlib.suppress(Exception): await stream.send().reset(1)
        finally:
            if writer is not None:
                writer.close()
                with contextlib.suppress(Exception): await writer.wait_closed()

    async def revoke(self, peer):
        async with self.lock:
            self.peers.discard(peer)
            await asyncio.to_thread(self._save_identity)
            if connection := self.connections.pop(peer, None): connection.close(0, b"pairing revoked")

    async def stop(self, disable=True):
        if disable and self.secret is not None:
            async with self.lock:
                self.enabled = False
                await asyncio.to_thread(self._save_identity)
        self.invite = None
        endpoint, self.endpoint = self.endpoint, None
        if self.accept_task is not None: self.accept_task.cancel()
        if endpoint is not None: await endpoint.close()
        tasks = list(self.tasks)
        for task in tasks: task.cancel()
        if tasks: await asyncio.gather(*tasks, return_exceptions=True)
        self.connections.clear()
