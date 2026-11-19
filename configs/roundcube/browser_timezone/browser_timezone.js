window.rcmail &&
  rcmail.addEventListener("init", function () {
    var tz;
    try {
      tz = Intl.DateTimeFormat().resolvedOptions().timeZone;
    } catch (e) {}

    if (tz && tz !== rcmail.env.browser_timezone) {
      rcmail.http_post("plugin.browser_timezone", { _timezone: tz });
    }
  });

// The server stored a new zone: redraw the message list so its dates use it.
// Other pages pick the zone up on their next load.
window.rcmail &&
  rcmail.addEventListener("plugin.browser_timezone", function () {
    if (rcmail.message_list) {
      rcmail.list_mailbox();
    }
  });
