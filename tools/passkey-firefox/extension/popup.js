// passkey-firefox, toolbar popup: the logins of the current tab's site (file names only). A button
// fills the page (the frame of the context menu click, else the top frame) or copies one field.
"use strict";

(async function () {
  var [tab] = await browser.tabs.query({ active: true, currentWindow: true });
  var status = document.getElementById("status");
  var reply = await browser.runtime.sendMessage({
    type: "logins",
    tabId: tab.id,
  });
  if (reply.error || !reply.logins.length) {
    status.textContent =
      reply.error || "No logins in the passage store for this site.";
    return;
  }
  reply.logins.forEach(function (entry) {
    var item = document.createElement("li");
    item.append(
      (entry.account ? entry.account + " @ " : "") + entry.site + " ",
    );
    function button(label, request) {
      var b = document.createElement("button");
      b.textContent = label;
      b.onclick = async function () {
        status.textContent = "…";
        var r = await browser.runtime.sendMessage({
          tabId: tab.id,
          site: entry.site,
          account: entry.account,
          ...request,
        });
        if (r.filled) window.close();
        status.textContent =
          r.error ||
          "Copied " + r.copied + ", cleared from the clipboard in 45 s.";
      };
      item.append(b);
    }
    button("fill", { type: "fill", frameId: reply.frameId });
    if (entry.user || entry.account)
      button("user", { type: "copy", field: "user" });
    button("pass", { type: "copy", field: "pass" });
    if (entry.otp) button("otp", { type: "copy", field: "otp" });
    document.getElementById("logins").append(item);
  });
})();
