def main() -> None:
    import logging

    import uvicorn

    # uvicorn only configures its own loggers; without this, scan progress
    # (faden_server.*) never reaches `docker compose logs`.
    logging.basicConfig(level=logging.INFO, format="%(asctime)s %(name)s: %(message)s")

    from .api import create_app
    from .config import load_settings

    settings = load_settings()
    app = create_app(settings)
    uvicorn.run(app, host="0.0.0.0", port=settings.port)
