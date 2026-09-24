def main() -> None:
    import uvicorn

    from .api import create_app
    from .config import load_settings

    settings = load_settings()
    app = create_app(settings)
    uvicorn.run(app, host="0.0.0.0", port=settings.port)
