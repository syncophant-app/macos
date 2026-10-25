#!/usr/bin/env python3
"""The loopback fixture must become ready without a working DNS resolver."""
import runpy
import sys
from pathlib import Path
from tempfile import TemporaryDirectory
from unittest.mock import patch
from urllib.parse import urlsplit

script = Path(__file__).parent / 'fixtures' / 'storage_http.py'
with TemporaryDirectory() as directory:
    ready = Path(directory) / 'ready'
    with patch.object(sys, 'argv', [str(script), '--ready-file', str(ready)]), \
         patch('socket.getfqdn', side_effect=AssertionError('Loopback startup must not resolve DNS')), \
         patch('http.server.ThreadingHTTPServer.serve_forever'):
        fixture = runpy.run_path(str(script), run_name='__main__')
    try:
        endpoint = urlsplit(ready.read_text())
        assert endpoint.scheme == 'http' and endpoint.hostname == '127.0.0.1' and endpoint.port > 0
    finally:
        fixture['server'].server_close()
print('HTTP fixture self-check passed: loopback startup without DNS.')
