"""nixcontalks: collect speakers' consent to release their NixCon talk videos.

Speakers get a mail from pretalx with the links /<proposal_code>/yes and
/<proposal_code>/no. Opening a link only shows a page with a button; the
answer is recorded when the button is pressed. Mail scanners and link
previews fetch links with GET, and must never answer for the speaker.

Only the codes in the --talks file (the confirmed talks exported from
pretalx) are accepted; the pages show the talk's title. The results list
only recorded talks of RESULT_TYPES. Every answer is
kept, so a talk with several speakers who disagree shows up in the results
with its whole history. The latest answer counts. The no page has a text
box for a reason, e.g. a license the speakers would agree to instead.
"""

import argparse
import csv
import html
import json
import logging
import re
import sqlite3
import sys
import threading
from datetime import datetime, timezone
from http import HTTPStatus
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs

log = logging.getLogger("nixcontalks")

# pretalx proposal codes are short upper-case alphanumerics (e.g. "ZQ7XRP").
PATH_RE = re.compile(r"^/([A-Za-z0-9]{4,16})/(yes|no)/?$")
LICENSE = "CC BY-SA 4.0"
LICENSE_URL = "https://creativecommons.org/licenses/by-sa/4.0/"
# Only these session types (pretalx names) are on the results, and only if
# they were recorded: workshops and do-not-record talks have no video.
RESULT_TYPES = {"Lightning talk", "Short talk", "Long talk"}
MAX_COMMENT = 4000
# Form-encoding can blow every character of the comment up to 9 bytes (%XX x3).
MAX_BODY = 9 * MAX_COMMENT + 64

SCHEMA = """
CREATE TABLE IF NOT EXISTS answers (
    id INTEGER PRIMARY KEY,
    code TEXT NOT NULL,
    answer TEXT NOT NULL CHECK (answer IN ('yes', 'no')),
    answered_at TEXT NOT NULL,
    comment TEXT NOT NULL DEFAULT ''
);
CREATE INDEX IF NOT EXISTS answers_code ON answers (code);
"""

STYLE = """
body { font-family: sans-serif; max-width: 36em; margin: 3em auto; padding: 0 1em; line-height: 1.5; }
button { font-size: 1.1em; padding: .5em 1.5em; cursor: pointer; }
.yes { color: #1a7f37; } .no { color: #b42318; }
textarea { width: 100%; min-height: 8em; font: inherit; box-sizing: border-box; }
pre { white-space: pre-wrap; margin: 0; }
body:has(table) { max-width: none; }
table { border-collapse: collapse; }
th, td { text-align: left; vertical-align: top; padding: .3em .8em; border-bottom: 1px solid #ccc; }
"""


class Store:
    def __init__(self, path: str) -> None:
        self.db = sqlite3.connect(path, check_same_thread=False)
        self.db.executescript(SCHEMA)
        self.lock = threading.Lock()

    def record(self, code: str, answer: str, comment: str) -> None:
        now = datetime.now(timezone.utc).isoformat(timespec="seconds")
        with self.lock, self.db:
            self.db.execute(
                "INSERT INTO answers (code, answer, answered_at, comment) VALUES (?, ?, ?, ?)",
                (code, answer, now, comment),
            )

    def current(self, code: str) -> tuple[str, str] | None:
        """Latest (answer, comment) for code."""
        with self.lock:
            row = self.db.execute(
                "SELECT answer, comment FROM answers WHERE code = ? ORDER BY id DESC LIMIT 1",
                (code,),
            ).fetchone()
        return (row[0], row[1]) if row else None

    def results(self, talks: dict[str, str]) -> list[tuple[str, str, str, str, str, str]]:
        """Per talk: code, title, latest answer ("" if none), its time, all
        answers oldest first, and every non-empty comment with the time and
        answer it came with."""
        with self.lock:
            rows = self.db.execute(
                "SELECT code, answer, answered_at, comment FROM answers ORDER BY id"
            ).fetchall()
        out: dict[str, tuple[str, str, list[str], list[str]]] = {
            code: ("", "", [], []) for code in talks
        }
        for code, answer, at, comment in rows:
            if code not in out:
                continue
            _, _, history, comments = out[code]
            history.append(answer)
            if comment:
                comments.append(f"{at} {answer}: {comment}")
            out[code] = (answer, at, history, comments)
        return [
            (c, talks[c], a, at, ",".join(h), "\n\n".join(cs))
            for c, (a, at, h, cs) in sorted(out.items())
        ]


def load_talks(path: str) -> tuple[dict[str, str], dict[str, str]]:
    """code -> title of every talk that may answer, and of the talks on the
    results: recorded ones of RESULT_TYPES. The file is a JSON list of
    {"code": ..., "title": ..., "type": ..., "recorded": ...}."""
    with open(path, encoding="utf-8") as f:
        talks = json.load(f)
    titles = {t["code"].upper(): t["title"] for t in talks}
    listed = {
        t["code"].upper(): t["title"]
        for t in talks
        if t["recorded"] and t["type"] in RESULT_TYPES
    }
    return titles, listed


def page(title: str, body: str) -> bytes:
    return (
        "<!doctype html><html lang=en><head><meta charset=utf-8>"
        '<meta name=viewport content="width=device-width, initial-scale=1">'
        '<meta name=robots content="noindex">'
        f"<title>{html.escape(title)}</title><style>{STYLE}</style></head>"
        f"<body><h1>{html.escape(title)}</h1>{body}</body></html>"
    ).encode()


def license_link() -> str:
    return f'<a href="{LICENSE_URL}">{LICENSE}</a>'


def talk(code: str, title: str) -> str:
    return f"<b>{html.escape(title)}</b> ({code})"


def question(code: str, title: str, answer: str, current: tuple[str, str] | None) -> bytes:
    if answer == "yes":
        text = (
            f"<p>Release the video of your talk {talk(code, title)} under {license_link()}?</p>"
            f'<form method=post><button class=yes>Yes, release it under {LICENSE}</button></form>'
        )
    else:
        previous = html.escape(current[1]) if current and current[0] == "no" else ""
        text = (
            f"<p>Don't release the video of your talk {talk(code, title)} under"
            f" {license_link()}? We will not publish the video then.</p>"
            "<form method=post>"
            "<p><label for=comment>Why not? If another license would work for you,"
            " or you have other conditions, tell us here (optional):</label></p>"
            f"<p><textarea id=comment name=comment maxlength={MAX_COMMENT}>{previous}</textarea></p>"
            "<button class=no>No, don't release it under this license</button></form>"
        )
    if current:
        text += f"<p>Your current answer is <b class={current[0]}>{current[0]}</b>.</p>"
    return page("NixCon talk recording license", text)


def answered(code: str, title: str, answer: str, comment: str) -> bytes:
    other = "no" if answer == "yes" else "yes"
    if answer == "yes":
        text = (
            f"<p class=yes>Thank you! The video of {talk(code, title)} will be released under"
            f" {license_link()}.</p>"
        )
    else:
        text = (
            f"<p class=no>Got it. The video of {talk(code, title)} will not be released"
            f" under {LICENSE}.</p>"
        )
        if comment:
            text += f"<p>Your comment:</p><pre>{html.escape(comment)}</pre>"
    text += f'<p>Changed your mind? <a href="/{code}/{other}">Answer {other} instead</a>.</p>'
    return page("NixCon talk recording license", text)


def results_page(rows: list[tuple[str, str, str, str, str, str]]) -> bytes:
    """Every talk, latest answer first; unanswered talks last, by code. Only
    behind the SSO (nginx)."""
    # answered_at is ISO 8601 UTC, so it sorts as a string; "" (unanswered)
    # sorts last in reverse, and the stable sort keeps those in code order.
    rows = sorted(sorted(rows), key=lambda r: r[3], reverse=True)
    count = {a: sum(r[2] == a for r in rows) for a in ("yes", "no", "")}
    text = (
        f"<p><b class=yes>{count['yes']} yes</b>, <b class=no>{count['no']} no</b>,"
        f" {count['']} not answered yet, of {len(rows)} talks</p>"
        "<table><tr><th>code</th><th>title</th><th>answer</th><th>answered at (UTC)</th>"
        "<th>history</th><th>comments</th></tr>"
    )
    for code, title, answer, at, history, comments in rows:
        text += (
            f"<tr><td>{code}</td><td>{html.escape(title)}</td>"
            f"<td class={answer or 'none'}>{answer or '–'}</td><td>{at}</td>"
            f"<td>{history}</td><td><pre>{html.escape(comments)}</pre></td></tr>"
        )
    text += "</table>"
    return page("NixCon talk recording license: answers", text)


def make_handler(
    store: Store, talks: dict[str, str], listed: dict[str, str]
) -> type[BaseHTTPRequestHandler]:
    class Handler(BaseHTTPRequestHandler):
        server_version = "nixcontalks"
        sys_version = ""

        def send(self, status: HTTPStatus, body: bytes) -> None:
            self.send_response(status)
            self.send_header("Content-Type", "text/html; charset=utf-8")
            self.send_header("Content-Length", str(len(body)))
            self.send_header("Cache-Control", "no-store")
            self.send_header("X-Robots-Tag", "noindex")
            self.end_headers()
            if self.command != "HEAD":
                self.wfile.write(body)

        def route(self) -> tuple[str, str] | None:
            """(code, answer) of a known talk; otherwise answers 404."""
            m = PATH_RE.match(self.path.split("?", 1)[0])
            code = m.group(1).upper() if m else None
            if code not in talks:
                self.send(
                    HTTPStatus.NOT_FOUND,
                    page("Not found", "<p>Please use the link from the mail you got.</p>"),
                )
                return None
            return code, m.group(2)

        def do_GET(self) -> None:
            # nginx only lets logged-in users (id.lassul.us) through to /results.
            if self.path.split("?", 1)[0] == "/results":
                self.send(HTTPStatus.OK, results_page(store.results(listed)))
                return
            r = self.route()
            if r:
                code, answer = r
                self.send(
                    HTTPStatus.OK, question(code, talks[code], answer, store.current(code))
                )

        do_HEAD = do_GET

        def do_POST(self) -> None:
            r = self.route()
            if not r:
                return
            length = int(self.headers.get("Content-Length") or 0)
            if length > MAX_BODY:
                self.send(HTTPStatus.REQUEST_ENTITY_TOO_LARGE, page("Too large", ""))
                return
            body = self.rfile.read(length).decode("utf-8", "replace")
            code, answer = r
            comment = ""
            if answer == "no":
                form = parse_qs(body)
                comment = form.get("comment", [""])[0].replace("\r\n", "\n").strip()
                comment = comment[:MAX_COMMENT]
            store.record(code, answer, comment)
            log.info("%s: %s%s", code, answer, " (with comment)" if comment else "")
            self.send(HTTPStatus.OK, answered(code, talks[code], answer, comment))

        def log_message(self, format: str, *args: object) -> None:
            pass

    return Handler


def serve(args: argparse.Namespace) -> None:
    logging.basicConfig(level=logging.INFO, format="%(levelname)s %(message)s")
    store = Store(args.database)
    talks, listed = load_talks(args.talks)
    server = ThreadingHTTPServer((args.host, args.port), make_handler(store, talks, listed))
    log.info(
        "listening on %s:%d, %d talks, %d on the results",
        args.host,
        args.port,
        len(talks),
        len(listed),
    )
    server.serve_forever()


def results(args: argparse.Namespace) -> None:
    w = csv.writer(sys.stdout)
    w.writerow(["code", "title", "answer", "answered_at", "history", "comments"])
    _, listed = load_talks(args.talks)
    w.writerows(Store(args.database).results(listed))


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument(
        "--database",
        default="/var/lib/nixcontalks/answers.db",
        help="SQLite database file (default: %(default)s)",
    )
    parser.add_argument(
        "--talks",
        required=True,
        help='JSON list of {"code", "title", "type", "recorded"}: the talks that may answer',
    )
    sub = parser.add_subparsers(dest="command", required=True)
    s = sub.add_parser("serve", help="serve the consent pages")
    s.add_argument("--host", default="127.0.0.1")
    s.add_argument("--port", type=int, required=True)
    s.set_defaults(func=serve)
    r = sub.add_parser(
        "results",
        help="print every talk with its latest answer and all comments as CSV",
    )
    r.set_defaults(func=results)
    args = parser.parse_args()
    args.func(args)


if __name__ == "__main__":
    main()
