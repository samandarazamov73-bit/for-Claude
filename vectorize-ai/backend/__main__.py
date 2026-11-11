"""Run the server: ``python -m backend [--host 0.0.0.0] [--port 8000]``."""
from __future__ import annotations

import argparse
import logging


def main() -> None:
    import uvicorn

    ap = argparse.ArgumentParser(prog="backend")
    ap.add_argument("--host", default="127.0.0.1")
    ap.add_argument("--port", type=int, default=8000)
    ap.add_argument("--reload", action="store_true")
    args = ap.parse_args()
    logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(name)s: %(message)s")
    uvicorn.run("backend.app:app", host=args.host, port=args.port, reload=args.reload, proxy_headers=True)


if __name__ == "__main__":
    main()
