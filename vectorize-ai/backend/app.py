"""ASGI entry point: ``uvicorn backend.app:app``."""
from .main import create_app

app = create_app()
