#!/usr/bin/env python3
"""
Mock CalDAV server for testing CalMirror.

Simulates a CalDAV server supporting PROPFIND, PUT, DELETE, and GET.
Events are stored in-memory (lost on restart) or optionally on disk.

Usage:
    python3 mock_caldav_server.py [--port 8008] [--user testuser] [--password testpass] [--persist]

Then configure CalMirror with:
    Server URL:     http://localhost:8008
    Calendar Path:  /calendars/testuser/default/
    Username:       testuser
    Password:       testpass
"""

import argparse
import base64
import os
import sys
import json
from datetime import datetime
from http.server import HTTPServer, BaseHTTPRequestHandler
from pathlib import Path

# In-memory event store: { "uid.ics": ics_content }
events: dict[str, str] = {}

# Configuration (set via CLI args)
config = {
    "user": "testuser",
    "password": "testpass",
    "calendar_path": "/calendars/testuser/default/",
    "persist_dir": None,
}


def log(method: str, path: str, status: int, detail: str = ""):
    ts = datetime.now().strftime("%H:%M:%S")
    msg = f"[{ts}] {method:8s} {path} -> {status}"
    if detail:
        msg += f"  ({detail})"
    print(msg)


class CalDAVHandler(BaseHTTPRequestHandler):
    """Handles CalDAV requests with Basic Auth."""

    def log_message(self, format, *args):
        # Suppress default logging; we use our own.
        pass

    # --- Authentication ---

    def _check_auth(self) -> bool:
        auth_header = self.headers.get("Authorization", "")
        if not auth_header.startswith("Basic "):
            self._send_error(401, "Unauthorized")
            return False

        try:
            decoded = base64.b64decode(auth_header[6:]).decode("utf-8")
            user, password = decoded.split(":", 1)
        except Exception:
            self._send_error(401, "Malformed Authorization header")
            return False

        if user != config["user"] or password != config["password"]:
            self._send_error(403, "Invalid credentials")
            return False

        return True

    # --- CalDAV Methods ---

    def do_PROPFIND(self):
        if not self._check_auth():
            return

        path = self._normalize_path()

        # Return a minimal 207 Multi-Status for the calendar collection
        body = f"""<?xml version="1.0" encoding="UTF-8"?>
<d:multistatus xmlns:d="DAV:" xmlns:cal="urn:ietf:params:xml:ns:caldav">
  <d:response>
    <d:href>{path}</d:href>
    <d:propstat>
      <d:prop>
        <d:displayname>CalMirror Test Calendar</d:displayname>
        <d:resourcetype>
          <d:collection/>
          <cal:calendar/>
        </d:resourcetype>
      </d:prop>
      <d:status>HTTP/1.1 200 OK</d:status>
    </d:propstat>
  </d:response>
</d:multistatus>"""

        self._send_response(207, body, content_type="application/xml; charset=utf-8")
        log("PROPFIND", path, 207)

    def do_PUT(self):
        if not self._check_auth():
            return

        path = self._normalize_path()
        content_length = int(self.headers.get("Content-Length", 0))
        ics_data = self.rfile.read(content_length).decode("utf-8") if content_length > 0 else ""

        if not ics_data.strip():
            self._send_error(400, "Empty body")
            log("PUT", path, 400, "empty body")
            return

        filename = path.rstrip("/").split("/")[-1]
        is_new = filename not in events

        events[filename] = ics_data
        self._persist_event(filename, ics_data)

        status = 201 if is_new else 204
        self._send_response(status, "")
        action = "created" if is_new else "updated"
        log("PUT", path, status, f"{action} {filename}")

    def do_DELETE(self):
        if not self._check_auth():
            return

        path = self._normalize_path()
        filename = path.rstrip("/").split("/")[-1]

        if filename in events:
            del events[filename]
            self._remove_persisted_event(filename)
            self._send_response(204, "")
            log("DELETE", path, 204, f"deleted {filename}")
        else:
            self._send_response(404, "")
            log("DELETE", path, 404, "not found")

    def do_GET(self):
        if not self._check_auth():
            return

        path = self._normalize_path()
        filename = path.rstrip("/").split("/")[-1]

        if filename in events:
            self._send_response(200, events[filename], content_type="text/calendar; charset=utf-8")
            log("GET", path, 200)
        elif path.rstrip("/") == config["calendar_path"].rstrip("/"):
            # List all events (simple HTML listing)
            listing = "<html><body><h1>CalMirror Test Calendar</h1><ul>"
            for name in sorted(events.keys()):
                listing += f'<li><a href="{config["calendar_path"]}{name}">{name}</a></li>'
            listing += "</ul></body></html>"
            self._send_response(200, listing, content_type="text/html; charset=utf-8")
            log("GET", path, 200, f"{len(events)} events")
        else:
            self._send_error(404, "Not found")
            log("GET", path, 404)

    def do_OPTIONS(self):
        self.send_response(200)
        self.send_header("Allow", "OPTIONS, GET, PUT, DELETE, PROPFIND")
        self.send_header("DAV", "1, 2, calendar-access")
        self.end_headers()
        log("OPTIONS", self.path, 200)

    # --- REPORT (calendar-multiget / calendar-query) ---

    def do_REPORT(self):
        if not self._check_auth():
            return

        path = self._normalize_path()

        # Return all events in a 207 Multi-Status
        responses = ""
        for filename, ics_data in events.items():
            responses += f"""
  <d:response>
    <d:href>{config["calendar_path"]}{filename}</d:href>
    <d:propstat>
      <d:prop>
        <d:getetag>"{hash(ics_data) & 0xFFFFFFFF:08x}"</d:getetag>
        <cal:calendar-data>{ics_data}</cal:calendar-data>
      </d:prop>
      <d:status>HTTP/1.1 200 OK</d:status>
    </d:propstat>
  </d:response>"""

        body = f"""<?xml version="1.0" encoding="UTF-8"?>
<d:multistatus xmlns:d="DAV:" xmlns:cal="urn:ietf:params:xml:ns:caldav">{responses}
</d:multistatus>"""

        self._send_response(207, body, content_type="application/xml; charset=utf-8")
        log("REPORT", path, 207, f"{len(events)} events")

    # --- Helpers ---

    def _normalize_path(self) -> str:
        return self.path.split("?")[0]

    def _send_response(self, status: int, body: str, content_type: str = "text/plain"):
        self.send_response(status)
        self.send_header("Content-Type", content_type)
        encoded = body.encode("utf-8")
        self.send_header("Content-Length", str(len(encoded)))
        self.send_header("DAV", "1, 2, calendar-access")
        self.end_headers()
        if encoded:
            self.wfile.write(encoded)

    def _send_error(self, status: int, message: str):
        self.send_response(status)
        if status == 401:
            self.send_header("WWW-Authenticate", 'Basic realm="CalMirror Test"')
        self.send_header("Content-Type", "text/plain")
        encoded = message.encode("utf-8")
        self.send_header("Content-Length", str(len(encoded)))
        self.end_headers()
        self.wfile.write(encoded)

    def _persist_event(self, filename: str, ics_data: str):
        if config["persist_dir"]:
            path = Path(config["persist_dir"]) / filename
            path.write_text(ics_data, encoding="utf-8")

    def _remove_persisted_event(self, filename: str):
        if config["persist_dir"]:
            path = Path(config["persist_dir"]) / filename
            path.unlink(missing_ok=True)


def _load_persisted_events():
    if config["persist_dir"]:
        persist_path = Path(config["persist_dir"])
        persist_path.mkdir(parents=True, exist_ok=True)
        for f in persist_path.glob("*.ics"):
            events[f.name] = f.read_text(encoding="utf-8")
        if events:
            print(f"Loaded {len(events)} persisted event(s) from {persist_path}")


def main():
    parser = argparse.ArgumentParser(description="Mock CalDAV server for CalMirror testing")
    parser.add_argument("--port", type=int, default=8008, help="Port to listen on (default: 8008)")
    parser.add_argument("--user", default="testuser", help="Username for Basic Auth (default: testuser)")
    parser.add_argument("--password", default="testpass", help="Password for Basic Auth (default: testpass)")
    parser.add_argument("--persist", action="store_true", help="Persist events to disk in ./caldav_data/")
    args = parser.parse_args()

    config["user"] = args.user
    config["password"] = args.password

    if args.persist:
        config["persist_dir"] = os.path.join(os.path.dirname(__file__), "caldav_data")

    _load_persisted_events()

    server = HTTPServer(("127.0.0.1", args.port), CalDAVHandler)
    print(f"Mock CalDAV server running on http://127.0.0.1:{args.port}")
    print(f"  Calendar path: {config['calendar_path']}")
    print(f"  Credentials:   {config['user']} / {config['password']}")
    print(f"  Persistence:   {'ON -> ./caldav_data/' if args.persist else 'OFF (in-memory only)'}")
    print()
    print("Configure CalMirror with:")
    print(f"  Server URL:     http://127.0.0.1:{args.port}")
    print(f"  Calendar Path:  {config['calendar_path']}")
    print(f"  Username:       {config['user']}")
    print(f"  Password:       {config['password']}")
    print()
    print("Press Ctrl+C to stop.")
    print("-" * 50)

    try:
        server.serve_forever()
    except KeyboardInterrupt:
        print("\nShutting down.")
        server.server_close()


if __name__ == "__main__":
    main()
