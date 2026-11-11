"""SSRF-safe image download for ``image.url`` / "paste a URL".

* only http(s), default or explicit ports 80/443/8080/8443, no credentials;
* every resolved address must be globally routable (no loopback, private,
  link-local incl. cloud metadata 169.254.169.254, CGNAT, multicast,
  reserved, IPv4-mapped private IPv6 ...);
* the TCP connection is pinned to the validated IP (Host header and TLS SNI
  carry the hostname), which defeats DNS rebinding;
* redirects are followed manually (max 3) and re-validated;
* the body is streamed with a hard byte limit and a total timeout.
"""
from __future__ import annotations

import asyncio
import ipaddress
import socket
from dataclasses import dataclass
from urllib.parse import unquote, urljoin, urlsplit, urlunsplit

import httpx

ALLOWED_PORTS = {80, 443, 8080, 8443}
MAX_REDIRECTS = 3


class FetchError(Exception):
    def __init__(self, code: str, message: str):
        super().__init__(message)
        self.code = code
        self.message = message


@dataclass
class Fetched:
    data: bytes
    filename: str
    content_type: str
    final_url: str


def ip_allowed(ip: str) -> bool:
    try:
        addr = ipaddress.ip_address(ip)
    except ValueError:
        return False
    if isinstance(addr, ipaddress.IPv6Address) and addr.ipv4_mapped is not None:
        addr = addr.ipv4_mapped
    if isinstance(addr, ipaddress.IPv6Address) and addr.sixtofour is not None:
        addr = addr.sixtofour
    return addr.is_global and not (addr.is_multicast or addr.is_reserved or addr.is_loopback or addr.is_link_local or addr.is_private)


def validate_url(url: str) -> tuple[str, str, int]:
    if not url or len(url) > 2048:
        raise FetchError("invalid_url", "URL is empty or too long.")
    parts = urlsplit(url.strip())
    if parts.scheme not in ("http", "https"):
        raise FetchError("invalid_url", "Only http and https URLs are supported.")
    if parts.username or parts.password:
        raise FetchError("invalid_url", "URLs with credentials are not allowed.")
    host = parts.hostname
    if not host:
        raise FetchError("invalid_url", "URL has no host.")
    port = parts.port or (443 if parts.scheme == "https" else 80)
    if port not in ALLOWED_PORTS:
        raise FetchError("url_not_allowed", f"Port {port} is not allowed.")
    return parts.scheme, host, port


async def resolve(host: str, port: int) -> list[str]:
    loop = asyncio.get_running_loop()
    try:
        infos = await asyncio.wait_for(loop.getaddrinfo(host, port, type=socket.SOCK_STREAM), 5)
    except (OSError, asyncio.TimeoutError) as exc:
        raise FetchError("url_unresolvable", f"Could not resolve host {host}.") from exc
    ips = []
    for info in infos:
        ip = info[4][0]
        if ip not in ips:
            ips.append(ip)
    return ips


async def fetch_image(url: str, *, max_bytes: int, allow_private: bool = False, timeout: float = 20.0, transport: httpx.AsyncBaseTransport | None = None) -> Fetched:
    current = url
    async with httpx.AsyncClient(follow_redirects=False, trust_env=False, timeout=httpx.Timeout(timeout, connect=8.0), transport=transport) as client:
        for _ in range(MAX_REDIRECTS + 1):
            scheme, host, port = validate_url(current)
            ips = await resolve(host, port)
            if not allow_private:
                bad = [ip for ip in ips if not ip_allowed(ip)]
                if bad or not ips:
                    raise FetchError("url_not_allowed", "The URL points to a private or reserved network address.")
            ip = ips[0]
            parts = urlsplit(current)
            ip_host = f"[{ip}]" if ":" in ip else ip
            pinned = urlunsplit((scheme, f"{ip_host}:{port}", parts.path or "/", parts.query, ""))
            host_header = host if port in (80, 443) else f"{host}:{port}"
            headers = {"Host": host_header, "User-Agent": "VectorizeAI-Fetcher/1.0", "Accept": "image/*"}
            ext = {"sni_hostname": host} if scheme == "https" else {}
            req = client.build_request("GET", pinned, headers=headers, extensions=ext)
            try:
                resp = await client.send(req, stream=True)
            except httpx.HTTPError as exc:
                raise FetchError("url_fetch_failed", f"Could not download the image: {type(exc).__name__}.") from exc
            try:
                if resp.status_code in (301, 302, 303, 307, 308):
                    loc = resp.headers.get("location")
                    if not loc:
                        raise FetchError("url_fetch_failed", "Redirect without location.")
                    current = urljoin(current, loc)
                    continue
                if resp.status_code != 200:
                    raise FetchError("url_fetch_failed", f"The server answered HTTP {resp.status_code}.")
                declared = resp.headers.get("content-length")
                if declared and declared.isdigit() and int(declared) > max_bytes:
                    raise FetchError("file_too_large", "The remote file is too large.")
                chunks, total = [], 0
                async for chunk in resp.aiter_bytes():
                    total += len(chunk)
                    if total > max_bytes:
                        raise FetchError("file_too_large", "The remote file is too large.")
                    chunks.append(chunk)
                name = unquote(parts.path.rsplit("/", 1)[-1]) or "image"
                return Fetched(b"".join(chunks), name[:120], resp.headers.get("content-type", ""), current)
            finally:
                await resp.aclose()
    raise FetchError("url_fetch_failed", "Too many redirects.")
