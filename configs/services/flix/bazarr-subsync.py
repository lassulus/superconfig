"""Syncs every external subtitle Bazarr knows to the audio of its video with
Bazarr's own sync (ffsubsync), once per version of the file. Bazarr only
syncs while downloading, so this covers the files from before that and the
syncs that went wrong. A subtitle whose sync fails or is rejected as low
quality goes to Bazarr's blacklist, which deletes it and searches another.

usage: bazarr-subsync URL CONFIG_YAML STATE_JSON
"""

import json
import os
import sys
import time
import urllib.parse
import urllib.request

import yaml

# seconds between looks at Bazarr's job queue, and the most a sync may take
POLL = float(os.environ.get("BAZARR_SUBSYNC_POLL", "10"))
TIMEOUT = 3600

url, config_file, state_file = sys.argv[1:]
with open(config_file) as f:
    config = yaml.safe_load(f)
base = url.rstrip("/") + config["general"]["base_url"].rstrip("/") + "/api/"
key = config["auth"]["apikey"]


def log(*args):
    print(*args, flush=True)


def api(method, endpoint, /, **params):
    data = urllib.parse.urlencode(params, doseq=True)
    req = urllib.request.Request(
        base + endpoint + ("?" + data if method == "GET" and data else ""),
        data=None if method == "GET" else data.encode(),
        method=method,
        headers={"X-API-KEY": key},
    )
    with urllib.request.urlopen(req, timeout=600) as r:
        body = r.read()
    return json.loads(body) if body.strip() else None


def subtitles():
    """yields (kind, id, series id, title, subtitle) for every subtitle"""
    for m in api("GET", "movies")["data"]:
        for s in m["subtitles"]:
            yield "movie", m["radarrId"], None, m["title"], s
    for series in api("GET", "series")["data"]:
        episodes = api("GET", "episodes", **{"seriesid[]": series["sonarrSeriesId"]})["data"]
        for e in episodes:
            for s in e["subtitles"]:
                title = "%s S%02dE%02d" % (series["title"], e["season"], e["episode"])
                yield "episode", e["sonarrEpisodeId"], e["sonarrSeriesId"], title, s


def history(kind, id, path):
    """the item's history entries for path, newest first"""
    if kind == "movie":
        entries = api("GET", "movies/history", radarrid=id)["data"]
    else:
        entries = api("GET", "episodes/history", episodeid=id)["data"]
    return [h for h in entries if h["subtitles_path"] == path]


def sync(kind, id, s):
    """syncs subtitle s and returns the description of Bazarr's history
    entry for it, None if the sync left none (it failed)"""
    path = s["path"]
    synced = lambda: [h for h in history(kind, id, path) if h["action"] == 5]  # noqa: E731
    before = len(synced())
    # the settings' max offset and quality checks apply; no_fix_framerate and
    # gss are False unless given
    api("PATCH", "subtitles", action="sync", type=kind, id=id, path=path, language=s["code2"],
        hi=str(s["hi"]), forced=str(s["forced"]), reference="a:0")
    names = {"Syncing " + path, "Synced " + path}
    deadline = time.monotonic() + TIMEOUT
    while any(j["job_name"] in names and j["status"] in ("pending", "running")
              for j in api("GET", "system/jobs")["data"]):
        if time.monotonic() > deadline:
            raise TimeoutError("sync of %s still not done" % path)
        time.sleep(POLL)
    after = synced()
    return after[0]["description"] if len(after) > before else None


def replace(kind, id, series_id, s):
    """blacklists subtitle s, so Bazarr deletes it and searches another"""
    path = s["path"]
    downloads = [h for h in history(kind, id, path) if h["provider"] and h["subs_id"]]
    if not downloads:
        log("%s: not downloaded by Bazarr, no provider to blacklist; keeping it" % path)
        return
    params = dict(provider=downloads[0]["provider"], subs_id=downloads[0]["subs_id"],
                  language=s["code2"], subtitles_path=path)
    if kind == "movie":
        api("POST", "movies/blacklist", radarrid=id, **params)
    else:
        api("POST", "episodes/blacklist", seriesid=series_id, episodeid=id, **params)
    log("%s: blacklisted %s %s, Bazarr searches another" % (path, params["provider"], params["subs_id"]))


try:
    with open(state_file) as f:
        state = json.load(f)
except FileNotFoundError:
    state = {}
ok = 0
for kind, id, series_id, title, s in subtitles():
    path = s["path"]
    # embedded tracks have no path; Bazarr cannot sync forced subtitles, and
    # writes SRT for everything but ASS
    if not path or s["forced"] or not path.endswith((".srt", ".ass")):
        continue
    try:
        mtime = os.stat(path).st_mtime
    except FileNotFoundError:
        continue
    if state.get(path) == mtime:
        continue
    desc = sync(kind, id, s)
    # the scale factor is only 0 when ffsubsync rejected the alignment
    if desc and "framerate scale factor of 0.00" not in desc:
        ok += 1
        log("%s: %s: %s" % (title, path, desc))
    elif desc or ok:
        log("%s: %s: %s" % (title, path, "low-quality alignment" if desc else "sync failed"))
        replace(kind, id, series_id, s)
    else:
        # nothing synced yet: maybe Bazarr cannot sync at all, so no blacklisting
        log("%s: %s: sync failed, trying again next run" % (title, path))
        continue
    try:
        mtime = os.stat(path).st_mtime
    except FileNotFoundError:
        pass
    state[path] = mtime
    with open(state_file + ".tmp", "w") as f:
        json.dump(state, f)
    os.replace(state_file + ".tmp", state_file)
