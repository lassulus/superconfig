"use strict";

const $ = (id) => document.getElementById(id);

// el("a", {href: ...}, child, ...): an element with properties and children
function el(tag, props, ...children) {
  const e = Object.assign(document.createElement(tag), props);
  e.append(...children.filter((c) => c !== null && c !== undefined));
  return e;
}

const time = (t) =>
  new Date(t).toLocaleTimeString([], { hour: "2-digit", minute: "2-digit" });
const day = (t) =>
  new Date(t).toLocaleDateString([], {
    weekday: "long",
    day: "numeric",
    month: "long",
  });
function length(ms) {
  const m = Math.round(ms / 60000);
  return m < 60 ? `${m} min` : `${Math.floor(m / 60)} h ${m % 60} min`;
}
const sources = { jellyfin: "Jellyfin", youtube: "YouTube" };

// the admin key, as an alternative to logging in
let key = localStorage.getItem("adminKey") ?? "";
let editor = "";

const authHeaders = () => (key ? { Authorization: `Bearer ${key}` } : {});

// a request from a form or a row: its controls stay disabled until it returns
async function send(form, path, body) {
  const controls = form.querySelectorAll("button, input");
  for (const c of controls) c.disabled = true;
  try {
    const res = await fetch(path, {
      method: body === undefined ? "GET" : "POST",
      headers: { "Content-Type": "application/json", ...authHeaders() },
      body: body === undefined ? undefined : JSON.stringify(body),
    });
    const out = res.status === 204 ? null : await res.json();
    if (!res.ok) throw new Error(out?.error ?? res.statusText);
    $("status").textContent = "";
    return out;
  } catch (e) {
    $("status").textContent = `Error: ${e.message}`;
    throw e;
  } finally {
    for (const c of controls) c.disabled = false;
  }
}

async function loadMe() {
  const me = await (
    await fetch("api/me", { headers: authHeaders(), cache: "no-store" })
  ).json();
  editor = me.name;
  if (!editor && key) {
    $("status").textContent = "Error: the admin key is wrong";
    key = "";
    localStorage.removeItem("adminKey");
  }
  $("who").textContent = editor ? `Editing as ${editor}` : "";
  $("login").hidden = !!editor || !me.login;
  $("keyform").hidden = !!editor;
  $("logout").hidden = !editor;
  $("editor").hidden = !editor;
}

let schedule = { entries: [], pending: [], slots: [] };
async function loadSchedule() {
  try {
    schedule = await (
      await fetch("api/schedule", { cache: "no-store" })
    ).json();
    render();
  } catch (e) {
    $("status").textContent = `Error: ${e.message}`;
  }
}

const ref = (e) => (e ? { start: e.start, id: e.id } : null);

// buttons of an entry: up, down and delete, for an upcoming one that is not a slot's
function editButtons(entries, i, playing) {
  const e = entries[i];
  if (!editor || e.slot || (i === 0 && playing)) return null;
  const form = el("form", {});
  const first = playing ? 1 : 0;
  const move = (after) => async () => {
    schedule = await send(form, "api/schedule/move", { ...ref(e), after });
    render();
  };
  const button = (text, title, onclick, disabled) =>
    el("button", {
      type: "button",
      textContent: text,
      title,
      onclick,
      disabled,
    });
  form.append(
    // after the one two up; the first one after the playing one cannot go up
    button("↑", "Move up", move(ref(entries[i - 2])), i === first),
    button(
      "↓",
      "Move down",
      move(ref(entries[i + 1])),
      i === entries.length - 1,
    ),
    button("✕", "Delete", async () => {
      schedule = await send(form, "api/schedule/delete", ref(e));
      render();
    }),
  );
  return form;
}

function render() {
  const now = Date.now();
  const { entries, pending, slots } = schedule;
  const playing = entries.length > 0 && entries[0].start <= now;
  const days = [];
  let last = "";
  let list = null;
  entries.forEach((e, i) => {
    const d = day(e.start);
    if (d !== last) {
      last = d;
      list = el("ol", {});
      days.push(el("h2", { textContent: d }), list);
    }
    const isPlaying = i === 0 && playing;
    const title = e.link
      ? el("a", {
          href: e.link,
          target: "_blank",
          rel: "noopener",
          textContent: e.title,
        })
      : e.title;
    list.append(
      el(
        "li",
        {
          className: [isPlaying && "playing", e.slot && "slot"]
            .filter(Boolean)
            .join(" "),
        },
        el("span", { className: "time", textContent: time(e.start) }),
        el(
          "span",
          { className: "title" },
          isPlaying
            ? el("span", { className: "tag", textContent: "now" })
            : null,
          e.slot ? el("span", { className: "tag", textContent: "slot" }) : null,
          " ",
          title,
        ),
        el("span", {
          className: "meta",
          // a slot cuts the entry before it short
          textContent: `${length(e.duration)}${e.length > e.duration ? ` of ${length(e.length)}` : ""} · ${sources[e.source] ?? e.source}`,
        }),
        editButtons(entries, i, playing),
      ),
    );
  });
  $("days").replaceChildren(
    ...(days.length
      ? days
      : [el("p", { textContent: "Nothing planned yet." })]),
  );

  $("slotbox").hidden = slots.length === 0;
  $("slots").replaceChildren(
    ...slots.map((s) => {
      const form = el("form", {});
      if (editor)
        form.append(
          el("button", {
            type: "button",
            textContent: "Remove",
            onclick: async () => {
              schedule = await send(form, "api/slots/remove", { id: s.id });
              render();
            },
          }),
        );
      return el(
        "li",
        { className: "slot" },
        el("span", {
          className: "time",
          textContent: `${day(s.at)}, ${time(s.at)}`,
        }),
        el("span", { className: "title", textContent: s.title }),
        el("span", {
          className: "meta",
          textContent: `${length(s.duration)} · ${sources[s.source] ?? s.source} · by ${s.by} · ${s.state}`,
        }),
        s.error
          ? el("span", { className: "error", textContent: s.error })
          : null,
        form,
      );
    }),
  );

  $("pendingbox").hidden = pending.length === 0;
  $("pending").replaceChildren(
    ...pending.map((r) =>
      el(
        "li",
        {},
        el("span", { className: "title", textContent: r.title }),
        el("span", {
          className: r.state === "failed" ? "error" : "meta",
          textContent: r.state === "failed" ? `failed: ${r.error}` : r.state,
        }),
      ),
    ),
  );
}

// the next full hour as a datetime-local value, in local time
function nextHour() {
  const d = new Date(Date.now() + 3600000);
  d.setMinutes(0, 0, 0);
  const p = (n) => String(n).padStart(2, "0");
  return `${d.getFullYear()}-${p(d.getMonth() + 1)}-${p(d.getDate())}T${p(d.getHours())}:00`;
}

$("search").addEventListener("submit", async (ev) => {
  ev.preventDefault();
  try {
    const found = await send(
      $("search"),
      "api/search?" + new URLSearchParams({ q: $("q").value }),
    );
    $("results").replaceChildren(
      ...(found.length ? found : [{ title: "Nothing found" }]).map((r) =>
        el(
          "li",
          {},
          r.id
            ? el("button", {
                type: "button",
                textContent: `${r.title}${r.year ? ` (${r.year})` : ""} · ${length(r.duration)}`,
                onclick: () => {
                  $("item").value = r.id;
                  $("added").textContent = `Picked: ${r.title}`;
                  $("results").replaceChildren();
                },
              })
            : r.title,
        ),
      ),
    );
  } catch {}
});

$("add").addEventListener("submit", async (ev) => {
  ev.preventDefault();
  try {
    const slot = await send($("add"), "api/slots/add", {
      url: $("item").value,
      at: new Date($("at").value).getTime(),
    });
    $("added").textContent =
      `Added: ${slot.title} on ${day(slot.at)}, ${time(slot.at)}`;
    $("item").value = "";
    loadSchedule();
  } catch {}
});

$("keyform").addEventListener("submit", async (ev) => {
  ev.preventDefault();
  key = $("key").value.trim();
  localStorage.setItem("adminKey", key);
  $("key").value = "";
  await loadMe();
  render();
});

$("logout").addEventListener("click", async () => {
  if (key) {
    key = "";
    localStorage.removeItem("adminKey");
  } else {
    await fetch("api/logout", { method: "POST" });
  }
  await loadMe();
  render();
});

$("at").value = nextHour();
(async () => {
  await loadMe().catch(
    (e) => ($("status").textContent = `Error: ${e.message}`),
  );
  await loadSchedule();
  setInterval(loadSchedule, 30000);
})();
