#!/usr/bin/env python3
"""Run against test_xiaozhi_core --serve; requires aiohttp. Synthetic credentials only."""
import asyncio
from aiohttp import ClientSession, ClientError, WSMsgType


async def main():
    origin = "http://127.0.0.1:18765"
    headers = {"Device-Id": "aa:bb:cc:00:01:02", "Protocol-Version": "1"}
    async with ClientSession() as client:
        async with client.get(origin + "/health") as response:
            assert response.status == 200
            assert not (await response.json())["device_bound"]
        async with client.post(origin + "/ota/wrong", headers=headers, json={}) as response:
            assert response.status == 403
        async with client.post(origin + "/ota/" + "a" * 48, headers=headers, json={}) as response:
            assert response.status == 200
            config = await response.json()
            assert "mqtt" not in config and "firmware" not in config
        async with client.post(origin + "/ota/" + "a" * 48,
                               headers={**headers, "Device-Id": "aa:bb:cc:00:01:03"}, json={}) as response:
            assert response.status == 403
        url = config["websocket"]["url"]
        try:
            await client.ws_connect(url, headers=headers)
            raise AssertionError("Unauthenticated WebSocket accepted")
        except ClientError:
            pass
        await asyncio.sleep(0.15)
        headers["Authorization"] = "Bearer " + config["websocket"]["token"]
        async with client.ws_connect(url, headers=headers, autoping=False) as ws:
            await ws.send_str("hello")
            message = await ws.receive(timeout=3)
            assert message.type == WSMsgType.TEXT and message.data == "hello"
            await ws.send_bytes(bytes(range(128)))
            message = await ws.receive(timeout=3)
            assert message.type == WSMsgType.BINARY and message.data == bytes(range(128))
            await ws.ping(b"test")
            assert (await ws.receive(timeout=3)).type == WSMsgType.PONG
            try:
                await client.ws_connect(url, headers=headers)
                raise AssertionError("Second concurrent device accepted")
            except ClientError:
                pass
        await asyncio.sleep(0.15)
        async with client.ws_connect(url, headers=headers) as ws:
            await ws.send_str("reconnected")
            assert (await ws.receive(timeout=3)).data == "reconnected"
            await ws.send_bytes(bytes(9000))
            assert (await ws.receive(timeout=3)).type in (WSMsgType.CLOSE, WSMsgType.CLOSED, WSMsgType.ERROR)
    print("PASS LAN provisioning, authentication, binary/text, ping, exclusivity, reconnect and size limit")


asyncio.run(main())
