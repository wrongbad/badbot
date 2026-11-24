"""mock.py DIR: a Chat Completions and Messages server for tests/test.sh, on 127.0.0.1.

Writes its port to DIR/port once it listens. The first path segment picks the
scenario (OPENAI_BASE_URL=http://127.0.0.1:PORT/text, for example); a scenario
starting a- is Anthropic's Messages API (ANTHROPIC_BASE_URL=…/a-text). The
body of each request is saved to DIR/request-SCENARIO.json, its auth header to
DIR/auth-SCENARIO, and for a- scenarios its anthropic-beta header to
DIR/beta-SCENARIO and the number of requests so far to DIR/count-SCENARIO.
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


def ev(type, **fields):
    return dict(type=type, **fields)


def block(index, **content_block):
    return ev("content_block_start", index=index, content_block=content_block)


def delta(index, **d):
    return ev("content_block_delta", index=index, delta=d)


A_START = ev("message_start", message={"id": "msg_1", "role": "assistant", "content": [],
                                       "usage": {"input_tokens": 6, "output_tokens": 1,
                                                 "cache_read_input_tokens": 4,
                                                 "cache_creation_input_tokens": 0}})


def a_end(stop):
    return [ev("message_delta", delta={"stop_reason": stop}, usage={"output_tokens": 2}),
            ev("message_stop")]


A_TEXT = [A_START,
          block(0, type="thinking", thinking="", signature=""),
          delta(0, type="thinking_delta", thinking="Hmm."),
          delta(0, type="signature_delta", signature="sig"),
          ev("content_block_stop", index=0),
          ev("ping"),
          block(1, type="text", text=""),
          delta(1, type="text_delta", text="Hel"),
          delta(1, type="text_delta", text="lo"),
          ev("content_block_stop", index=1)] + a_end("end_turn")

A_STREAMS = {
    "a-text": A_TEXT,
    "a-tools": [A_START,
                block(0, type="text", text=""),
                delta(0, type="text_delta", text="Let me look."),
                block(1, type="tool_use", id="toolu_1", name="shell", input={}),
                delta(1, type="input_json_delta", partial_json='{"comm'),
                delta(1, type="input_json_delta", partial_json='and":"ls"}'),
                block(2, type="tool_use", id="toolu_2", name="shell", input={}),
                delta(2, type="input_json_delta", partial_json=""),
                ] + a_end("tool_use"),
    "a-midstream": [A_START, ev("error", error={"type": "invalid_request_error", "message": "bad thing"})],
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
            f.write(self.headers.get("Authorization", "") or self.headers.get("x-api-key", ""))
        if scenario.startswith("a-"):
            return self.anthropic(scenario)
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

    def anthropic(self, scenario):
        with open(os.path.join(DIR, "beta-%s" % scenario), "w") as f:
            f.write(self.headers.get("anthropic-beta", ""))
        counter = os.path.join(DIR, "count-%s" % scenario)
        n = int(open(counter).read()) + 1 if os.path.exists(counter) else 1
        with open(counter, "w") as f:
            f.write(str(n))
        if scenario == "a-unauthorized":
            return self.plain(401, {"type": "error", "error": {"type": "authentication_error",
                                                               "message": "invalid x-api-key"}})
        if scenario == "a-overloaded" and n < 3:  # twice, then the stream
            return self.plain(529, {"type": "error", "error": {"type": "overloaded_error", "message": "Overloaded"}})
        if scenario == "a-busy":  # always
            return self.plain(529, {"type": "error", "error": {"type": "overloaded_error", "message": "Overloaded"}})
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.send_header("Connection", "close")
        self.end_headers()
        try:
            if scenario == "a-slow":  # some text, then nothing for a long while
                for e in [A_START, block(0, type="text", text=""), delta(0, type="text_delta", text="partial "),
                          delta(0, type="text_delta", text="text"),
                          block(1, type="tool_use", id="toolu_9", name="shell", input={})]:
                    self.sse(e)
                time.sleep(20)
                return
            for e in A_STREAMS.get(scenario, A_TEXT):
                self.sse(e)
        except (BrokenPipeError, ConnectionResetError):
            pass

    def sse(self, e):
        self.wfile.write(("event: %s\ndata: %s\n\n" % (e["type"], json.dumps(e))).encode())
        self.wfile.flush()

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
