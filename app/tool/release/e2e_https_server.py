"""CI only: serves a folder over HTTPS (localhost, test certificate) for the Windows update end-to-end test.

    python e2e_https_server.py <folder> <cert.pem> <key.pem> [port]
"""
import functools
import http.server
import ssl
import sys

folder, cert, key = sys.argv[1], sys.argv[2], sys.argv[3]
port = int(sys.argv[4]) if len(sys.argv) > 4 else 8443


class Handler(http.server.SimpleHTTPRequestHandler):
    def end_headers(self):
        self.send_header('Cache-Control', 'no-cache')
        super().end_headers()

    def log_message(self, fmt, *args):
        sys.stderr.write('[e2e-https] ' + (fmt % args) + '\n')
        sys.stderr.flush()


httpd = http.server.ThreadingHTTPServer(('127.0.0.1', port), functools.partial(Handler, directory=folder))
ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
ctx.load_cert_chain(cert, key)
httpd.socket = ctx.wrap_socket(httpd.socket, server_side=True)
print(f'serving {folder} on https://localhost:{port}/', flush=True)
httpd.serve_forever()
