// passkey-firefox, background: user/password/OTP autofill from the passage store.
//
// A login is a folder with pass.age (user.age, otp.age optional): www/<site>/ or a subfolder
// per further account, whose name is the user name when it has no user.age (PassFF). The sites
// of a tab are its host and parent domains down to the registrable one (loginSites).
//
// Listing reads file names only. Nothing is decrypted, and nothing reaches a page, until the user
// picks a login in the toolbar popup (also opened by the context menu of an input field). A fill
// decrypts what the page has fields for: user.age and pass.age with `pass show`, otp.age with
// `pass otp`, one approval of the hardware key each. Only the frame the user clicked (or the top
// frame) is filled, and only when it has the tab's origin.
"use strict";

var menuFrames = new Map(); // tab id -> frame id of the last context menu click

async function loginsOf(tab) {
  var url = secureOrigin(tab.url);
  if (!url) return [];
  var entries = [];
  for (var site of loginSites(url.hostname, await publicSuffixes())) {
    var names = (await host({ op: "logins", rp: site })).names;
    for (var name of names.filter((n) => n === "pass" || n.endsWith("/pass"))) {
      var account = name.slice(0, -"/pass".length);
      var prefix = account ? account + "/" : "";
      entries.push({
        site: site,
        account: account,
        user: names.includes(prefix + "user"),
        otp: names.includes(prefix + "otp"),
      });
    }
  }
  return entries;
}

// The first line of a field; the user name of a login without user.age is its folder name.
async function value(entry, field) {
  if (field === "user" && !entry.user) return entry.account || undefined;
  if (field === "otp" && !entry.otp) return undefined;
  var name = (entry.account ? entry.account + "/" : "") + field;
  var reply = await host({
    op: field === "otp" ? "otp" : "read",
    rp: entry.site,
    name: name,
  });
  var bytes = Uint8Array.from(atob(reply.data), (c) => c.charCodeAt(0));
  return new TextDecoder().decode(bytes).split("\n")[0];
}

// Runs in the frame (isolated world). Without values: which login fields the frame has. With
// values: fills them. Null when the frame is not of `origin`.
function formFields(origin, values) {
  if (location.origin !== origin) return null;
  var inputs = Array.from(document.querySelectorAll("input")).filter(
    (el) =>
      !el.disabled &&
      !el.readOnly &&
      el.getClientRects().length &&
      getComputedStyle(el).visibility !== "hidden",
  );
  var label = (el) => el.name + " " + el.id + " " + el.autocomplete;
  var otp = inputs.find(
    (el) =>
      el.autocomplete === "one-time-code" ||
      /otp|totp|2fa|mfa|one.?time/i.test(label(el)),
  );
  var focused = inputs.includes(document.activeElement)
    ? document.activeElement
    : null;
  var pass =
    focused && focused.type === "password"
      ? focused
      : inputs.find((el) => el.type === "password");
  var texts = inputs.filter(
    (el) => el !== otp && ["text", "email", "tel"].includes(el.type),
  );
  var user =
    texts.find((el) => /username|email/.test(el.autocomplete)) ||
    (pass
      ? texts
          .filter(
            (el) =>
              el.compareDocumentPosition(pass) &
              Node.DOCUMENT_POSITION_FOLLOWING,
          )
          .pop()
      : texts.find((el) =>
          /user|login|mail|name/i.test(label(el) + " " + el.type),
        ));
  var fields = { user: user, pass: pass, otp: otp };
  if (!values) return { user: !!user, pass: !!pass, otp: !!otp };
  Object.keys(values).forEach(function (field) {
    var el = fields[field];
    el.focus();
    el.value = values[field];
    el.dispatchEvent(new Event("input", { bubbles: true }));
    el.dispatchEvent(new Event("change", { bubbles: true }));
  });
  return true;
}

async function fill(tab, frameId, entry) {
  var origin = secureOrigin(tab.url).origin;
  var inFrame = (values) =>
    browser.scripting
      .executeScript({
        target: { tabId: tab.id, frameIds: [frameId] },
        func: formFields,
        args: [origin, values],
      })
      .then((results) => results[0].result);
  var found = await inFrame(null);
  if (!found) throw new Error("refused: the frame is not of the tab's origin");
  var values = {};
  for (var field of ["user", "pass", "otp"]) {
    var v = found[field] ? await value(entry, field) : undefined;
    if (v !== undefined) values[field] = v;
  }
  if (!Object.keys(values).length) throw new Error("no login fields here");
  if (!(await inFrame(values))) throw new Error("refused: the frame navigated");
  return Object.keys(values);
}

// The clipboard is cleared after 45 s if it still holds the copy (compared by hash, the value
// itself is not kept). An alarm, as the background page may sleep meanwhile.
async function digest(text) {
  return hex(await sha256(new TextEncoder().encode(text)));
}

async function copy(entry, field) {
  var v = await value(entry, field);
  if (v === undefined) throw new Error("no " + field + " for this login");
  await navigator.clipboard.writeText(v);
  await browser.storage.session.set({ copied: await digest(v) });
  browser.alarms.create("clear-clipboard", { delayInMinutes: 0.75 });
  return field;
}

browser.alarms.onAlarm.addListener(async function (alarm) {
  if (alarm.name !== "clear-clipboard") return;
  var { copied } = await browser.storage.session.get("copied");
  await browser.storage.session.remove("copied");
  if (copied && (await digest(await navigator.clipboard.readText())) === copied)
    await navigator.clipboard.writeText("");
});

browser.runtime.onInstalled.addListener(function () {
  browser.menus.create({
    id: "fill-login",
    title: "Fill login from passage…",
    contexts: ["editable", "password"],
  });
});

browser.menus.onClicked.addListener(function (info, tab) {
  if (info.menuItemId !== "fill-login") return;
  menuFrames.set(tab.id, info.frameId);
  browser.action.openPopup();
});

// Requests of the popup (extension pages only; content scripts never get here).
browser.runtime.onMessage.addListener(function (msg, sender) {
  if (
    sender.id !== browser.runtime.id ||
    !sender.url.startsWith(browser.runtime.getURL(""))
  )
    return;
  return (async function () {
    var tab = await browser.tabs.get(msg.tabId);
    if (msg.type === "logins") {
      var frameId = menuFrames.get(tab.id) || 0;
      menuFrames.delete(tab.id);
      return { logins: await loginsOf(tab), frameId: frameId };
    }
    var entry = (await loginsOf(tab)).find(
      (e) => e.site === msg.site && e.account === msg.account,
    );
    if (!entry) throw new Error("no such login for this tab");
    if (msg.type === "fill")
      return { filled: await fill(tab, msg.frameId || 0, entry) };
    if (msg.type === "copy") return { copied: await copy(entry, msg.field) };
    throw new Error("bad request");
  })().catch((e) => ({
    error: e.unavailable
      ? "the passkey_firefox host is not installed"
      : e.message,
  }));
});
