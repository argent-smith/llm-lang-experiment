import threading

import pytest
from werkzeug.serving import make_server

from syncbox_server.app import create_app
from syncbox_server.config import Config


@pytest.fixture
def live_server(tmp_path):
    data_dir = tmp_path / "server-data"
    data_dir.mkdir()
    app = create_app(Config(data_dir=str(data_dir), port=0))
    httpd = make_server("127.0.0.1", 0, app)
    thread = threading.Thread(target=httpd.serve_forever, daemon=True)
    thread.start()
    try:
        yield f"http://127.0.0.1:{httpd.server_port}", data_dir
    finally:
        httpd.shutdown()
        thread.join()
