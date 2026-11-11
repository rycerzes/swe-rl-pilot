"""Domain-allowlisting HTTP proxy for the agent's sandbox. Standard library only, Python >= 3.8.

Usage: python3 allowlist_proxy.py --port 47121 --allow router.huggingface.co --allow .trycloudflare.com
       [--log /var/log/pilot-egress.log]

Started as root before the agent. The agent then runs under landlock_exec.py, which only lets it
open TCP connections to this port, so every connection it makes goes through here:
- `CONNECT host:443` (HTTPS) is tunnelled only if host is allowed;
- plain HTTP requests with an absolute URL are forwarded only if the host is allowed;
- anything else gets 403 and a log line (host, port, verdict), for atif-scan or the reward function.

An --allow entry starting with "." matches that domain and its subdomains; otherwise the host
must match exactly. IP-literal hosts are never allowed (no name to check).
"""

from __future__ import annotations

import argparse
import asyncio
import ipaddress
import time

ALLOW: list[str] = []
LOG = None


def allowed(host: str) -> bool:
    host = host.strip("[]").rstrip(".").lower()
    try:
        ipaddress.ip_address(host)
        return False
    except ValueError:
        pass
    for rule in ALLOW:
        if rule.startswith("."):
            if host == rule[1:] or host.endswith(rule):
                return True
        elif host == rule:
            return True
    return False


def log(host: str, port: int, verdict: str) -> None:
    if LOG:
        with open(LOG, "a") as fh:
            fh.write(f"{time.time():.3f}\t{verdict}\t{host}\t{port}\n")


async def pipe(reader: asyncio.StreamReader, writer: asyncio.StreamWriter) -> None:
    try:
        while data := await reader.read(65536):
            writer.write(data)
            await writer.drain()
    except (ConnectionError, asyncio.CancelledError):
        pass
    finally:
        writer.close()


async def handle(reader: asyncio.StreamReader, writer: asyncio.StreamWriter) -> None:
    try:
        head = await reader.readuntil(b"\r\n\r\n")
    except (asyncio.IncompleteReadError, asyncio.LimitOverrunError, ConnectionError):
        writer.close()
        return
    request_line = head.split(b"\r\n", 1)[0].decode("latin-1")
    try:
        method, target, _ = request_line.split(" ", 2)
    except ValueError:
        writer.close()
        return
    if method.upper() == "CONNECT":
        host, _, port_text = target.rpartition(":")
        port = int(port_text) if port_text.isdigit() else 443
        rest = b""
    else:
        if not target.lower().startswith("http://"):
            writer.write(b"HTTP/1.1 400 Bad Request\r\nContent-Length: 0\r\n\r\n")
            await writer.drain()
            writer.close()
            return
        authority = target[7:].split("/", 1)[0]
        host, _, port_text = authority.rpartition(":") if ":" in authority else (authority, "", "80")
        port = int(port_text) if port_text.isdigit() else 80
        rest = head
    if not allowed(host):
        log(host, port, "DENY")
        writer.write(b"HTTP/1.1 403 Forbidden\r\nContent-Length: 0\r\nConnection: close\r\n\r\n")
        await writer.drain()
        writer.close()
        return
    try:
        up_reader, up_writer = await asyncio.wait_for(asyncio.open_connection(host, port), 30)
    except (OSError, asyncio.TimeoutError):
        log(host, port, "FAIL")
        writer.write(b"HTTP/1.1 502 Bad Gateway\r\nContent-Length: 0\r\nConnection: close\r\n\r\n")
        await writer.drain()
        writer.close()
        return
    log(host, port, "ALLOW")
    if method.upper() == "CONNECT":
        writer.write(b"HTTP/1.1 200 Connection Established\r\n\r\n")
        await writer.drain()
    else:
        up_writer.write(rest)
        await up_writer.drain()
    await asyncio.gather(pipe(reader, up_writer), pipe(up_reader, writer))


async def main() -> None:
    global LOG
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--port", type=int, default=47121)
    parser.add_argument("--allow", action="append", default=[])
    parser.add_argument("--log")
    args = parser.parse_args()
    ALLOW.extend(a.lower() for a in args.allow)
    LOG = args.log
    server = await asyncio.start_server(handle, "127.0.0.1", args.port)
    async with server:
        await server.serve_forever()


if __name__ == "__main__":
    asyncio.run(main())
