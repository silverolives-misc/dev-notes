#!/usr/bin/env python3
"""
Minimal Jira REST v2 stand-in for developing the patching workflow offline.

    python3 dev/mock_jira.py 8765 &
    export JIRA_URL=http://127.0.0.1:8765 JIRA_USER=mock-user JIRA_TOKEN=mock-token-x7

Use token values that cannot appear in Jira data: Ansible masks every
occurrence of a secret in task output, so a token of "dev" would turn the
patch group "dev_oci" into "********_oci".

Serves any issue key. Behaviour per key suffix, so one server covers the
gate's paths:
    CHG-1    Approved, window open, patch group dev_oci, no host list
    CHG-2    Awaiting approval              → gate halts
    CHG-3    Approved, window closed        → gate halts
    CHG-4    Approved, host list "oltest01" → scope from ticket
POSTed comments / attachments / transitions are appended to
dev/mock_jira.log (relative to the current directory).
"""
import json
import sys
from datetime import datetime, timedelta, timezone
from http.server import BaseHTTPRequestHandler, HTTPServer

LOG = "dev/mock_jira.log"
FMT = "%Y-%m-%dT%H:%M:%S.000+0000"


def issue(key):
    now = datetime.now(timezone.utc)
    start, end = now - timedelta(hours=1), now + timedelta(hours=4)
    status, hosts = "Approved", ""
    if key.endswith("-2"):
        status = "Awaiting approval"
    elif key.endswith("-3"):
        start, end = now + timedelta(days=1), now + timedelta(days=1, hours=4)
    elif key.endswith("-4"):
        hosts = "oltest01"
    return {
        "key": key,
        "fields": {
            "summary": f"Dev patching run {key}",
            "issuetype": {"name": "Change"},
            "status": {"name": status},
            "customfield_10001": {"value": "dev_oci"},
            "customfield_10002": hosts,
            "customfield_10003": start.strftime(FMT),
            "customfield_10004": end.strftime(FMT),
        },
    }


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def _send(self, code, body=None):
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.end_headers()
        if body is not None:
            self.wfile.write(json.dumps(body).encode())

    def do_GET(self):
        parts = self.path.split("/")
        if self.path.startswith("/rest/api/2/issue/") and len(parts) == 6:
            self._send(200, issue(parts[5]))
        else:
            self._send(404, {})

    def do_POST(self):
        data = self.rfile.read(int(self.headers.get("Content-Length", 0)))
        with open(LOG, "ab") as f:
            f.write(f"=== {datetime.now().isoformat()} POST {self.path}\n".encode())
            f.write(data[:20000] + b"\n")
        if self.path.endswith("/comment"):
            self._send(201, {"id": "1"})
        elif self.path.endswith("/attachments"):
            self._send(200, [{"id": "2"}])
        elif self.path.endswith("/transitions"):
            self._send(204)
        else:
            self._send(404, {})


if __name__ == "__main__":
    port = int(sys.argv[1]) if len(sys.argv) > 1 else 8765
    print(f"mock Jira on http://127.0.0.1:{port} — POSTs logged to {LOG}")
    HTTPServer(("127.0.0.1", port), Handler).serve_forever()
