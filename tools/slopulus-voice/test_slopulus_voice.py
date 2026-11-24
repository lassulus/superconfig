"""Tests of slopulus-voice's tasks against a fake Hermes API server.

Run: python3 -m unittest test_slopulus_voice (from this directory).

The fake runs the turns of one session one after the other, like Hermes's
session authority does, so delegations that share a session wait for each
other there.
"""

import json
import threading
import time
import unittest
import urllib.error
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

import slopulus_voice as voice

TIMEOUT = 5


class FakeRun:
    def __init__(self, run_id, body):
        self.id = run_id
        self.session = body["session_id"]
        self.input = body["input"]
        self.instructions = body["instructions"]
        self.output = None
        self.approval = None
        self.answer = None
        self.stopped = False
        self.finished = False


class FakeHermes:
    """Sessions, forks, runs (one at a time per session) and webhook routes."""

    def __init__(self):
        self.cond = threading.Condition()
        self.sessions = {}
        self.forks = []
        self.runs = []
        self.stops = []
        self.posts = []
        fake = self

        class Handler(BaseHTTPRequestHandler):
            def log_message(self, *args):
                pass

            def reply(self, status, payload):
                body = json.dumps(payload).encode()
                self.send_response(status)
                self.send_header("Content-Type", "application/json")
                self.send_header("Content-Length", str(len(body)))
                self.end_headers()
                self.wfile.write(body)

            def body(self):
                length = int(self.headers.get("Content-Length") or 0)
                return json.loads(self.rfile.read(length)) if length else {}

            def do_POST(self):
                body = self.body()
                parts = self.path.strip("/").split("/")
                with fake.cond:
                    if self.path.startswith("/webhooks/"):
                        fake.posts.append((parts[1], body))
                        fake.cond.notify_all()
                        return self.reply(200, {"status": "delivered"})
                    if parts == ["api", "sessions"]:
                        if body["id"] in fake.sessions:
                            return self.reply(409, {"error": "exists"})
                        fake.sessions[body["id"]] = None
                        return self.reply(201, {"session": {"id": body["id"]}})
                    if parts[:2] == ["api", "sessions"] and parts[3:] == ["fork"]:
                        if parts[2] not in fake.sessions:
                            return self.reply(404, {"error": "no session"})
                        if body["id"] in fake.sessions:
                            return self.reply(409, {"error": "exists"})
                        fake.sessions[body["id"]] = parts[2]
                        fake.forks.append((parts[2], body["id"], body.get("title")))
                        return self.reply(201, {"session": {"id": body["id"]}})
                    if parts == ["v1", "runs"]:
                        run = FakeRun(f"run_{len(fake.runs) + 1}", body)
                        fake.runs.append(run)
                        fake.cond.notify_all()
                        return self.reply(202, {"run_id": run.id, "status": "started"})
                    run = fake.run(parts[2])
                    if parts[3] == "stop":
                        fake.stops.append(run.id)
                        run.stopped = True
                    elif parts[3] == "approval":
                        run.answer = body
                    fake.cond.notify_all()
                    return self.reply(200, {"status": "ok"})

            def do_GET(self):
                parts = self.path.strip("/").split("/")
                run = fake.run(parts[2])
                self.send_response(200)
                self.send_header("Content-Type", "text/event-stream")
                self.end_headers()

                def event(payload):
                    self.wfile.write(f"data: {json.dumps(payload)}\n\n".encode())
                    self.wfile.flush()

                with fake.cond:
                    # Hermes: one turn of a session at a time.
                    fake.cond.wait_for(lambda: fake.first_unfinished(run.session) is run or run.stopped)
                if not run.stopped:
                    event({"event": "tool.started", "tool": "terminal", "preview": run.id})
                with fake.cond:
                    fake.cond.wait_for(lambda: run.stopped or run.output is not None or run.approval)
                    approval = run.approval
                if approval and not run.stopped:
                    event({"event": "approval.request", **approval})
                    with fake.cond:
                        fake.cond.wait_for(lambda: run.stopped or run.output is not None)
                with fake.cond:
                    run.finished = True
                    fake.cond.notify_all()
                if run.stopped:
                    event({"event": "run.cancelled"})
                else:
                    event({"event": "run.completed", "output": run.output})

        self.server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        self.server.daemon_threads = True
        self.url = f"http://127.0.0.1:{self.server.server_address[1]}"
        threading.Thread(target=self.server.serve_forever, daemon=True).start()

    def run(self, run_id):
        return next(run for run in self.runs if run.id == run_id)

    def first_unfinished(self, session):
        return next((run for run in self.runs if run.session == session and not run.finished), None)

    def finish(self, run, output):
        with self.cond:
            run.output = output
            self.cond.notify_all()

    def ask_approval(self, run, command):
        with self.cond:
            run.approval = {"request_id": "req1", "command": command, "description": "delete"}
            self.cond.notify_all()

    def wait_runs(self, count):
        with self.cond:
            self.cond.wait_for(lambda: len(self.runs) >= count, TIMEOUT)
            return list(self.runs)

    def wait_post(self, predicate):
        with self.cond:
            self.cond.wait_for(lambda: any(predicate(route, body) for route, body in self.posts), TIMEOUT)
            return [(route, body) for route, body in self.posts if predicate(route, body)]


class Stream:
    """One /delegate request read in the background, like a page does.

    The fake sees a run before the server has registered its task (that
    happens when POST /v1/runs returned); the stream's first item, the task,
    comes after the registration, so tests wait for it (wait_items) before
    they look the task up."""

    def __init__(self, url, session, said, replace=False):
        self.items = []
        self.cond = threading.Condition()
        self.done = threading.Event()
        body = {
            "hermes_session": session,
            "lines": [{"speaker": "user", "text": said}],
            "replace": replace,
        }
        request = urllib.request.Request(
            f"{url}/delegate",
            data=json.dumps(body).encode(),
            method="POST",
            headers={"Content-Type": "application/json"},
        )
        threading.Thread(target=self.read, args=(request,), daemon=True).start()

    def read(self, request):
        with urllib.request.urlopen(request, timeout=30) as response:
            for line in response:
                if line.strip():
                    with self.cond:
                        self.items.append(json.loads(line))
                        self.cond.notify_all()
        self.done.set()
        with self.cond:
            self.cond.notify_all()

    def wait_items(self, count):
        """Wait for `count` items (1: the task is registered, 2: it runs)."""
        with self.cond:
            if not self.cond.wait_for(lambda: len(self.items) >= count or self.done.is_set(), TIMEOUT):
                raise AssertionError(f"no {count} items from /delegate: {self.items}")

    def answer(self):
        self.done.wait(TIMEOUT)
        return "".join(item["text"] for item in self.items if item["type"] == "delta")

    def last(self):
        self.done.wait(TIMEOUT)
        return self.items[-1] if self.items else None


class TasksTest(unittest.TestCase):
    def setUp(self):
        self.hermes = FakeHermes()
        config = voice.Config(
            {},
            openai_key="openai",
            hermes_url=self.hermes.url,
            hermes_key="key",
            matrix_webhook=f"{self.hermes.url}/webhooks/voice-approval",
            transcript_webhook=f"{self.hermes.url}/webhooks/voice-transcript",
        )
        config.task_webhook = f"{self.hermes.url}/webhooks/voice-task"
        handler = type("Handler", (voice.Handler,), {"config": config, "access_token": None})
        self.server = ThreadingHTTPServer(("127.0.0.1", 0), handler)
        self.server.daemon_threads = True
        self.url = f"http://127.0.0.1:{self.server.server_address[1]}"
        threading.Thread(target=self.server.serve_forever, daemon=True).start()
        self.call = f"voice-test-{id(self)}"

    def tearDown(self):
        # Let the tasks' followers end before the fake goes away.
        for run in self.hermes.runs:
            if not run.finished:
                self.hermes.finish(run, "cleanup")
        self.server.shutdown()
        self.server.server_close()
        self.hermes.server.shutdown()
        self.hermes.server.server_close()

    def get(self, path):
        with urllib.request.urlopen(f"{self.url}{path}", timeout=TIMEOUT) as response:
            return json.load(response)

    def post(self, path, payload):
        request = urllib.request.Request(
            f"{self.url}{path}",
            data=json.dumps(payload).encode(),
            method="POST",
            headers={"Content-Type": "application/json"},
        )
        with urllib.request.urlopen(request, timeout=TIMEOUT) as response:
            return json.load(response)

    def tasks(self):
        return {task["task"]: task for task in self.get(f"/tasks?call={self.call}")["tasks"]}

    def wait_state(self, task, state):
        deadline = time.monotonic() + TIMEOUT
        while time.monotonic() < deadline:
            if self.tasks()[task]["state"] == state:
                return
            time.sleep(0.05)
        self.fail(f"{task} never got {state}: {self.tasks()[task]}")

    def test_quick_request_answers_while_a_long_one_runs(self):
        long = Stream(self.url, self.call, "dispatch a coding agent for the CI failure")
        long_run = self.hermes.wait_runs(1)[0]
        quick = Stream(self.url, self.call, "turn the lights off")
        quick_run = self.hermes.wait_runs(2)[1]
        self.hermes.finish(quick_run, "The lights are off.")
        self.assertEqual(quick.answer(), "The lights are off.")
        self.assertFalse(long.done.is_set(), "the long task ended with the quick one")
        self.assertNotEqual(long_run.session, quick_run.session)
        # Both are forks of the call's session, so they see the conversation.
        self.assertEqual(
            {(source, session) for source, session, _ in self.hermes.forks},
            {(self.call, long_run.session), (self.call, quick_run.session)},
        )
        self.hermes.finish(long_run, "The agent is on it.")
        self.assertEqual(long.answer(), "The agent is on it.")

    def test_replace_stops_no_other_task_and_stop_ends_only_its_own(self):
        first = Stream(self.url, self.call, "book a table for Friday")
        first.wait_items(1)
        second = Stream(self.url, self.call, "what is the weather")
        second.wait_items(1)
        # Both clients send replace whenever another delegation still runs.
        correction = Stream(self.url, self.call, "no, make it Thursday", replace=True)
        correction.wait_items(1)
        runs = self.hermes.wait_runs(3)
        self.assertEqual(self.hermes.stops, [])
        self.wait_state("t3", "running")
        # The correcting task knows what it may correct.
        self.assertIn('t1 "book a table for Friday": running', runs[2].instructions)
        self.assertIn('t2 "what is the weather": running', runs[2].instructions)

        # What its voice_task_stop does: stop exactly t1.
        stopped = self.post("/tasks/stop", {"call": self.call, "task": "t1"})
        self.assertEqual(stopped["task"], "t1")
        self.assertEqual(self.hermes.stops, [runs[0].id])
        self.assertEqual(first.last()["finish_reason"], "cancelled")
        self.wait_state("t1", "stopped")
        self.assertEqual(self.tasks()["t2"]["state"], "running")
        self.assertFalse(second.done.is_set())

        self.hermes.finish(runs[2], "Thursday it is.")
        self.assertEqual(correction.answer(), "Thursday it is.")
        self.hermes.finish(runs[1], "Sunny.")
        self.assertEqual(second.answer(), "Sunny.")
        with self.assertRaises(urllib.error.HTTPError) as again:
            self.post("/tasks/stop", {"call": self.call, "task": "t1"})
        self.assertEqual(again.exception.code, 409)
        again.exception.close()

    def test_task_list(self):
        stream = Stream(self.url, self.call, "check the backups")
        run = self.hermes.wait_runs(1)[0]
        # The task item, then the run's first tool step.
        stream.wait_items(2)
        self.wait_state("t1", "running")
        task = self.tasks()["t1"]
        self.assertEqual(task["title"], "check the backups")
        self.assertEqual(task["session"], run.session)
        self.assertEqual(task["progress"], "terminal: run_1")
        self.assertEqual(stream.items[0], {"type": "task", "task": "t1", "title": "check the backups", "session": run.session})
        self.hermes.finish(run, "All backups are fine.")
        stream.answer()
        self.wait_state("t1", "done")
        self.assertEqual(self.tasks()["t1"]["result"], "All backups are fine.")
        # A later task hears about the finished one.
        Stream(self.url, self.call, "and the disks?")
        later = self.hermes.wait_runs(2)[1]
        self.assertIn('t1 "check the backups": done', later.instructions)
        self.assertIn("result: All backups are fine.", later.instructions)

    def test_result_and_unheard_approval_go_to_the_task_thread(self):
        stream = Stream(self.url, self.call, "clean up the tmp dir")
        stream.wait_items(1)
        run = self.hermes.wait_runs(1)[0]
        self.post("/tasks/thread", {"session": run.session, "thread_id": "$root"})
        # The call ends before slopulus asks.
        self.post("/hangup", {"hermes_session": self.call, "lines": [], "call": []})
        self.hermes.ask_approval(run, "rm -rf /tmp/x")
        [(_, asked)] = self.hermes.wait_post(lambda route, body: "approval" in body["text"])
        self.assertEqual(asked["thread_id"], "$root")
        code = asked["text"].split("/assist approve ")[1][:4]
        self.post("/approve", {"code": code, "choice": "once"})
        self.assertEqual(run.answer["choice"], "once")
        self.hermes.finish(run, "Cleaned up.")
        [(route, result)] = self.hermes.wait_post(lambda route, body: body["text"] == "Cleaned up.")
        self.assertEqual((route, result["thread_id"]), ("voice-task", "$root"))

    def test_hang_up_keeps_tasks_and_delegates_the_rest(self):
        stream = Stream(self.url, self.call, "deploy coaxmetal")
        stream.wait_items(1)
        running = self.hermes.wait_runs(1)[0]
        hangup = self.post(
            "/hangup",
            {
                "hermes_session": self.call,
                "lines": [{"speaker": "user", "text": "and send me the log in Matrix"}],
                "call": [{"speaker": "user", "text": "deploy coaxmetal"}],
            },
        )
        self.assertEqual(hangup["task"], "t2")
        late = self.hermes.wait_runs(2)[1]
        self.assertIn("already hung up", late.instructions)
        self.assertFalse(running.stopped)
        [(_, transcript)] = self.hermes.wait_post(lambda route, body: route == "voice-transcript")
        self.assertIn("t1: deploy coaxmetal (running)", transcript["text"])
        self.hermes.finish(running, "Deployed.")
        self.assertEqual(stream.answer(), "Deployed.")


if __name__ == "__main__":
    unittest.main()
