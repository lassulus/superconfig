// passkey-firefox, content script: carries requests between page.js (same frame, page world) and
// background.js. Only messages this frame's window posted to itself are taken; the browser
// tells background.js which frame sent them.
(function () {
  "use strict";

  var REQUEST = "passkey-firefox-request:";
  var ABORT = "passkey-firefox-abort:";
  var RESULT = "passkey-firefox-result:";

  function reply(message) {
    window.postMessage(RESULT + JSON.stringify(message), "*");
  }

  window.addEventListener("message", function (event) {
    if (event.source !== window || typeof event.data !== "string") return;
    var data = event.data;
    var type =
      data.indexOf(REQUEST) === 0
        ? "request"
        : data.indexOf(ABORT) === 0
          ? "abort"
          : null;
    if (!type) return;
    var message;
    try {
      message = JSON.parse(
        data.slice(type === "request" ? REQUEST.length : ABORT.length),
      );
    } catch (e) {
      return;
    }
    if (typeof message.id !== "number") return;
    if (type === "abort") {
      browser.runtime
        .sendMessage({ type: "abort", id: message.id })
        .catch(function () {});
      return;
    }
    browser.runtime
      .sendMessage({
        type: "request",
        id: message.id,
        op: message.op,
        body: message.body,
      })
      .then(
        function (result) {
          reply(Object.assign({ id: message.id }, result));
        },
        function () {
          reply({ id: message.id, ok: false, dom: "NotAllowedError" });
        },
      );
  });
})();
