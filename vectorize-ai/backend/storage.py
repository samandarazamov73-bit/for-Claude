"""Per-image file storage. Paths are derived only from server-generated
tokens, never from user input, and every file write is atomic."""
from __future__ import annotations

import gzip
import json
import os
import re
import secrets
import shutil
from pathlib import Path

_TOKEN_RE = re.compile(r"^[A-Za-z0-9_-]{20,64}$")


def new_token() -> str:
    return secrets.token_urlsafe(24)


class Storage:
    def __init__(self, root: Path):
        self.root = Path(root) / "images"
        self.root.mkdir(parents=True, exist_ok=True)

    def dir(self, token: str) -> Path:
        if not _TOKEN_RE.match(token or ""):
            raise ValueError("invalid token")
        return self.root / token

    def _write(self, path: Path, data: bytes) -> None:
        path.parent.mkdir(parents=True, exist_ok=True)
        tmp = path.with_suffix(path.suffix + ".tmp")
        with open(tmp, "wb") as f:
            f.write(data)
        os.replace(tmp, path)

    def write_source(self, token: str, data: bytes) -> None:
        self._write(self.dir(token) / "source.bin", data)

    def source_path(self, token: str) -> Path:
        return self.dir(token) / "source.bin"

    def read_source(self, token: str) -> bytes:
        return self.source_path(token).read_bytes()

    def graph_path(self, token: str) -> Path:
        return self.dir(token) / "graph.json.gz"

    def preview_path(self, token: str) -> Path:
        return self.dir(token) / "source.png"

    def thumb_path(self, token: str) -> Path:
        return self.dir(token) / "thumb.png"

    def cache_dir(self, token: str) -> Path:
        return self.dir(token) / "cache"

    def save_graph(self, token: str, graph_json: dict) -> None:
        raw = json.dumps(graph_json, separators=(",", ":")).encode()
        self._write(self.graph_path(token), gzip.compress(raw, 6))

    def load_graph_json(self, token: str) -> dict:
        with gzip.open(self.graph_path(token), "rb") as f:
            return json.loads(f.read())

    def has_graph(self, token: str) -> bool:
        return self.graph_path(token).exists()

    def delete(self, token: str) -> None:
        shutil.rmtree(self.dir(token), ignore_errors=True)

    def copy_source(self, src_token: str, dst_token: str) -> None:
        self._write(self.source_path(dst_token), self.read_source(src_token))
