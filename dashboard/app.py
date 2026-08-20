#!/usr/bin/env python3
"""
Bouncer report dashboard — read-only web UI over the encrypted SQLCipher database.

Uses only the Python standard library. Queries are executed through the
`sqlcipher` CLI (already installed in the Bouncer image), mirroring the
approach in scripts/db_helper.sh. Text columns are selected as hex() and
decoded here, so arbitrary report content can never corrupt the output
framing.

Environment:
  DB_PASSPHRASE   optional SQLCipher key for the database. When set, the
                  vault is unlocked for all visitors. When unset, the UI
                  prompts each visitor for the passphrase on connect and the
                  browser sends it per request via the X-DB-Passphrase
                  header; it is never stored server-side.
  DB_PATH         path to bouncer.db          (default: /out/bouncer.db)
  DASHBOARD_PORT  port to listen on           (default: 5001)
  DASHBOARD_HOST  interface to bind           (default: 0.0.0.0)
  DASHBOARD_TOKEN optional bearer token; when set, all requests must send
                  `Authorization: Bearer <token>` (recommended — reports
                  contain sensitive vulnerability details)
"""

import json
import os
import subprocess
import sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlparse

DB_PATH = os.environ.get("DB_PATH", "/out/bouncer.db")
PASSPHRASE = os.environ.get("DB_PASSPHRASE", "")
PORT = int(os.environ.get("DASHBOARD_PORT", "5001"))
HOST = os.environ.get("DASHBOARD_HOST", "0.0.0.0")
TOKEN = os.environ.get("DASHBOARD_TOKEN", "")

STATIC_DIR = os.path.join(os.path.dirname(os.path.abspath(__file__)), "static")


class DatabaseError(Exception):
    pass


def run_sql(query, passphrase):
    """Run a read-only query against the encrypted DB and return stdout.

    The database may be in SQLCipher 3.x format (created by older Bouncer
    images whose Debian base shipped sqlcipher 3.x). SQLCipher 4.x clients
    reject such files with "file is not a database" unless compatibility
    mode is enabled, so on that specific error we retry with
    cipher_compatibility = 3 (the pragma must come *after* PRAGMA key).
    """
    if not passphrase:
        raise DatabaseError("no database passphrase provided")
    if not os.path.isfile(DB_PATH):
        raise DatabaseError(f"database not found at {DB_PATH}")
    key = passphrase.replace("'", "''")
    attempts = [
        [f"PRAGMA key = '{key}';"],
        [f"PRAGMA key = '{key}';", "PRAGMA cipher_compatibility = 3;"],
    ]
    last_err = "sqlcipher query failed"
    for pragmas in attempts:
        cmd = ["sqlcipher", "-batch", "-list", "-noheader"]
        for pragma in pragmas:
            cmd += ["-cmd", pragma]
        cmd += [DB_PATH, query]
        result = subprocess.run(cmd, capture_output=True, text=True, timeout=30)
        if result.returncode == 0:
            return result.stdout
        last_err = result.stderr.strip() or last_err
        if "file is not a database" not in result.stderr:
            break  # not a cipher-format problem — don't retry
    raise DatabaseError(last_err)


def unhex(value):
    """Decode a hex()-encoded column back to text ('' stays '')."""
    if not value:
        return ""
    try:
        return bytes.fromhex(value).decode("utf-8", errors="replace")
    except ValueError:
        return ""


def fetch_reports(passphrase):
    """All report rows, newest first. report_text itself is not included."""
    out = run_sql(
        "SELECT id, hex(repo), pr_number, hex(COALESCE(head_oid, '')), "
        "created_at, hex(COALESCE(metrics_json, '')), length(report_text), "
        "hex(substr(COALESCE(report_text, ''), 1, 1024)) "
        "FROM pr_reports ORDER BY created_at DESC, id DESC;",
        passphrase,
    )
    reports = []
    for line in out.splitlines():
        if not line.strip():
            continue
        # Strip the "ok" line SQLCipher 4.x prints for PRAGMA key
        if line == "ok":
            continue
        parts = line.split("|")
        if len(parts) != 8:
            continue
        rid, repo_hex, pr, oid_hex, created, metrics_hex, text_len, head_hex = parts
        metrics_raw = unhex(metrics_hex)
        try:
            metrics = json.loads(metrics_raw) if metrics_raw else None
        except json.JSONDecodeError:
            metrics = {"raw": metrics_raw}
        reports.append({
            "id": int(rid),
            "repo": unhex(repo_hex),
            "pr_number": int(pr),
            "head_oid": unhex(oid_hex),
            "created_at": created,
            "metrics": metrics,
            "report_size": int(text_len),
            "report_head": unhex(head_hex),
        })
    return reports


def fetch_report(report_id, passphrase):
    out = run_sql(
        f"SELECT hex(COALESCE(report_text, '')) FROM pr_reports "
        f"WHERE id = {int(report_id)};",
        passphrase,
    )
    for line in out.splitlines():
        if line == "ok" or not line.strip():
            continue
        return unhex(line.strip())
    return None


def fetch_ledgers(passphrase):
    out = run_sql(
        "SELECT hex(repo), hex(COALESCE(ledger_text, '')), updated_at "
        "FROM backfill_ledger ORDER BY repo;",
        passphrase,
    )
    ledgers = []
    for line in out.splitlines():
        if line == "ok" or not line.strip():
            continue
        parts = line.split("|")
        if len(parts) != 3:
            continue
        repo_hex, text_hex, updated = parts
        ledgers.append({
            "repo": unhex(repo_hex),
            "ledger_text": unhex(text_hex),
            "updated_at": updated,
        })
    return ledgers


def fetch_review_count(passphrase):
    out = run_sql("SELECT count(*) FROM pr_reviews;", passphrase)
    for line in out.splitlines():
        if line == "ok" or not line.strip():
            continue
        try:
            return int(line.strip())
        except ValueError:
            return 0
    return 0


class DashboardHandler(BaseHTTPRequestHandler):
    server_version = "BouncerDashboard/1.0"

    # Quieter logging: one line per request, like a normal access log
    def log_message(self, fmt, *args):
        sys.stderr.write("%s - %s\n" % (self.address_string(), fmt % args))

    def _authorized(self):
        if not TOKEN:
            return True
        return self.headers.get("Authorization") == f"Bearer {TOKEN}"

    def _passphrase(self):
        """Per-request vault key: visitor-supplied header wins, else the
        boot-time DB_PASSPHRASE fallback."""
        return self.headers.get("X-DB-Passphrase") or PASSPHRASE

    def _send_json(self, payload, status=200):
        body = json.dumps(payload).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(body)

    def _send_error_json(self, message, status):
        self._send_json({"error": message}, status=status)

    def do_GET(self):
        path = urlparse(self.path).path.rstrip("/") or "/"

        # The page and the health probe are public so the browser can render
        # the unlock prompt and learn what credentials to ask for; all data
        # routes stay behind DASHBOARD_TOKEN when it is set.
        if path not in ("/", "/api/health") and not self._authorized():
            self._send_error_json("unauthorized", 401)
            return

        try:
            if path == "/":
                self._serve_index()
            elif path == "/api/health":
                self._send_json({
                    "ok": True,
                    "auth": bool(TOKEN),
                    "passphrase_required": not PASSPHRASE,
                })
            elif path == "/api/reports":
                passphrase = self._passphrase()
                if not passphrase:
                    self._send_error_json("passphrase_required", 428)
                    return
                self._send_json({
                    "reports": fetch_reports(passphrase),
                    "reviews_tracked": fetch_review_count(passphrase),
                })
            elif path.startswith("/api/reports/"):
                report_id = path.rsplit("/", 1)[-1]
                if not report_id.isdigit():
                    self._send_error_json("invalid report id", 400)
                    return
                passphrase = self._passphrase()
                if not passphrase:
                    self._send_error_json("passphrase_required", 428)
                    return
                text = fetch_report(int(report_id), passphrase)
                if text is None:
                    self._send_error_json("report not found", 404)
                    return
                self._send_json({"id": int(report_id), "report_text": text})
            elif path == "/api/ledgers":
                passphrase = self._passphrase()
                if not passphrase:
                    self._send_error_json("passphrase_required", 428)
                    return
                self._send_json({"ledgers": fetch_ledgers(passphrase)})
            else:
                self._send_error_json("not found", 404)
        except DatabaseError as exc:
            # A decryption failure means the supplied passphrase was wrong
            if "file is not a database" in str(exc):
                self._send_error_json("bad_passphrase", 401)
            else:
                self._send_error_json(str(exc), 503)
        except subprocess.TimeoutExpired:
            self._send_error_json("database query timed out", 504)

    def _serve_index(self):
        index_path = os.path.join(STATIC_DIR, "index.html")
        try:
            with open(index_path, "rb") as fh:
                body = fh.read()
        except OSError:
            self._send_error_json("dashboard assets missing", 500)
            return
        self.send_response(200)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(body)


def main():
    server = ThreadingHTTPServer((HOST, PORT), DashboardHandler)
    print(f"Bouncer dashboard listening on http://{HOST}:{PORT} (db: {DB_PATH})")
    if PASSPHRASE:
        print("Vault unlocked at boot via DB_PASSPHRASE — visitors are not prompted.")
    else:
        print("DB_PASSPHRASE not set — visitors will be prompted for the "
              "database passphrase on connect.")
    if not TOKEN:
        print("WARNING: DASHBOARD_TOKEN is not set — the dashboard is "
              "unauthenticated. Reports may contain sensitive findings.",
              file=sys.stderr)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    main()
