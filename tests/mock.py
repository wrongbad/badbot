"""mock.py DIR: a Chat Completions server for tests/test.sh, on 127.0.0.1.

Writes its port to DIR/port once it listens. The first path segment picks the
scenario (OPENAI_BASE_URL=http://127.0.0.1:PORT/text, for example); the body
of each request is saved to DIR/request-SCENARIO.json.
"""
import json
import os
import sys
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

DIR = sys.argv[1]


def chunk(delta=None, finish=None, **extra):
    c = {"choices": [{"index": 0, "delta": delta or {}, "finish_reason": finish}]}
    c.update(extra)
    return c


def call(index=None, id=None, name=None, args=None):
    tc = {}
    if index is not None:
        tc["index"] = index
    if id is not None:
        tc["id"] = id
        tc["type"] = "function"
    fn = {}
    if name is not None:
        fn["name"] = name
    if args is not None:
        fn["arguments"] = args
    tc["function"] = fn
    return chunk({"tool_calls": [tc]})


USAGE = {"choices": [], "usage": {"prompt_tokens": 10, "completion_tokens": 2,
                                  "prompt_tokens_details": {"cached_tokens": 4}}}
TEXT = [chunk({"role": "assistant", "content": ""}), chunk({"content": "Hel"}),
        chunk({"content": "lo"}), chunk(finish="stop"), USAGE]

# scenario: list of chunks, sent as SSE
STREAMS = {
    "text": TEXT,
    "kernel": TEXT,  # the same stream, for openai_kernel: its request is saved apart from openai_text's
    "nospace": TEXT,
    "crlf": TEXT,
    "tools": [
        chunk({"role": "assistant", "content": "Let me look."}),
        call(0, "call_1", "shell", ""),
        call(0, args='{"comm'),
        call(1, "call_2", "shell", '{"command":'),
        call(0, args='and":"ls"}'),
        call(1, args='"date","wait":0}'),
        chunk(finish="tool_calls"),
    ],
    "noindex": [
        call(id="a", name="shell", args=""),
        call(args='{"command":'),
        call(args='"pwd"}'),
        call(id="b", name="shell", args='{"command":"date"}'),
        chunk(finish="tool_calls"),
    ],
    "stopcalls": [
        call(0, "call_9", "shell", '{"command":"true"}'),
        chunk(finish="stop"),
    ],
}


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *args):
        pass

    def do_POST(self):
        scenario = self.path.strip("/").split("/")[0]
        body = self.rfile.read(int(self.headers.get("Content-Length", 0)))
        with open(os.path.join(DIR, "request-%s.json" % scenario), "wb") as f:
            f.write(body)
        with open(os.path.join(DIR, "auth-%s" % scenario), "w") as f:
            f.write(self.headers.get("Authorization", ""))
        if scenario == "unauthorized":
            return self.plain(401, {"error": {"message": "Incorrect API key provided: sk-test",
                                              "type": "invalid_request_error", "code": "invalid_api_key"}})
        if scenario == "strerror":
            return self.plain(404, {"error": "model not found"})
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.send_header("Connection", "close")
        self.end_headers()
        nl = "\r\n" if scenario == "crlf" else "\n"
        prefix = "data:" if scenario == "nospace" else "data: "
        try:
            if scenario == "slow":  # some text, then nothing for a long while
                self.send(prefix, chunk({"content": "partial "}), nl)
                self.send(prefix, chunk({"content": "text"}), nl)
                time.sleep(20)
                return
            self.wfile.write((": keep-alive" + nl + nl).encode())
            for c in STREAMS.get(scenario, TEXT):
                self.send(prefix, c, nl)
            self.wfile.write((prefix + "[DONE]" + nl + nl).encode())
            self.wfile.flush()
        except (BrokenPipeError, ConnectionResetError):
            pass

    def send(self, prefix, obj, nl):
        self.wfile.write((prefix + json.dumps(obj) + nl + nl).encode())
        self.wfile.flush()

    def plain(self, status, obj):
        data = json.dumps(obj).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.send_header("Connection", "close")
        self.end_headers()
        self.wfile.write(data)


server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
server.daemon_threads = True
with open(os.path.join(DIR, "port.tmp"), "w") as f:
    f.write(str(server.server_address[1]))
os.rename(os.path.join(DIR, "port.tmp"), os.path.join(DIR, "port"))
server.serve_forever()
