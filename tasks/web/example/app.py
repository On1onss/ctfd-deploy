from http.server import BaseHTTPRequestHandler, HTTPServer

FLAG = "flag{example_task_flag}"


class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        self.send_response(200)
        self.send_header("Content-Type", "text/plain; charset=utf-8")
        self.end_headers()
        self.wfile.write(FLAG.encode())


if __name__ == "__main__":
    HTTPServer(("0.0.0.0", 8000), Handler).serve_forever()