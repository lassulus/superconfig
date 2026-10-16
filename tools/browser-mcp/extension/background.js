/* Browser MCP - Firefox side of the browser-mcp bridge.
 *
 * Connects to the browser_mcp native messaging host, which relays requests
 * from MCP servers over a unix socket. Everything runs through the regular
 * WebExtension APIs, so the browser never enters WebDriver/Marionette mode:
 * navigator.webdriver stays false and captcha providers see a normal browser.
 *
 * Request:  {id, method, params}
 * Response: {id, result} | {id, error}
 */

const HOST = "browser_mcp";
const DEFAULT_LOAD_TIMEOUT_MS = 15000;

let port = null;
let retryDelay = 1000;

function connect() {
  port = browser.runtime.connectNative(HOST);
  port.onMessage.addListener(onRequest);
  port.onDisconnect.addListener((p) => {
    console.warn("browser-mcp host disconnected:", p.error);
    port = null;
    setTimeout(connect, retryDelay);
    retryDelay = Math.min(retryDelay * 2, 60000);
  });
}

async function onRequest(msg) {
  // Any message means the host is up; reset backoff for the next reconnect.
  retryDelay = 1000;
  let reply;
  try {
    const handler = handlers[msg.method];
    if (!handler) throw new Error(`unknown method: ${msg.method}`);
    reply = { id: msg.id, result: await handler(msg.params || {}) };
  } catch (e) {
    reply = { id: msg.id, error: String(e && e.message ? e.message : e) };
  }
  if (port) port.postMessage(reply);
}

function tabInfo(t) {
  return {
    id: t.id,
    windowId: t.windowId,
    active: t.active,
    status: t.status,
    title: t.title,
    url: t.url,
  };
}

// Runs `start` (which returns the tab id) and resolves once that tab reports
// status "complete", or after the timeout (the page keeps loading; the
// caller gets loaded: false). The listener goes up before `start` so a fast
// load can't complete unseen.
function navigateAndWait(start, timeoutMs) {
  return new Promise((resolve, reject) => {
    const completed = new Set();
    let tabId = null;
    let timer = null;
    const cleanup = () => {
      clearTimeout(timer);
      browser.tabs.onUpdated.removeListener(listener);
    };
    const finish = async (loaded) => {
      cleanup();
      try {
        resolve({ loaded, tab: tabInfo(await browser.tabs.get(tabId)) });
      } catch (e) {
        reject(e);
      }
    };
    const listener = (id, change) => {
      if (change.status !== "complete") return;
      if (tabId === null) completed.add(id);
      else if (id === tabId) finish(true);
    };
    browser.tabs.onUpdated.addListener(listener);
    start().then(
      (id) => {
        tabId = id;
        if (completed.has(id)) finish(true);
        else timer = setTimeout(() => finish(false), timeoutMs);
      },
      (e) => {
        cleanup();
        reject(e);
      },
    );
  });
}

// Content-side helpers live in the extension's isolated world of the page
// (page.js), invisible to the page's own scripts.
async function pageCall(tabId, op, args) {
  const [present] = await browser.tabs.executeScript(tabId, {
    code: "typeof __browserMcp !== 'undefined'",
  });
  if (!present) await browser.tabs.executeScript(tabId, { file: "/page.js" });
  const [result] = await browser.tabs.executeScript(tabId, {
    code: `__browserMcp.${op}(${JSON.stringify(args)})`,
  });
  return result;
}

const handlers = {
  async list_tabs() {
    return (await browser.tabs.query({})).map(tabInfo);
  },

  async open_tab({
    url,
    active = false,
    timeout_ms = DEFAULT_LOAD_TIMEOUT_MS,
  }) {
    return navigateAndWait(
      async () => (await browser.tabs.create({ url, active })).id,
      timeout_ms,
    );
  },

  async navigate({ tab_id, url, timeout_ms = DEFAULT_LOAD_TIMEOUT_MS }) {
    return navigateAndWait(async () => {
      await browser.tabs.update(tab_id, { url });
      return tab_id;
    }, timeout_ms);
  },

  async history({ tab_id, direction, timeout_ms = DEFAULT_LOAD_TIMEOUT_MS }) {
    if (direction !== "back" && direction !== "forward") {
      throw new Error("direction must be 'back' or 'forward'");
    }
    return navigateAndWait(async () => {
      if (direction === "back") await browser.tabs.goBack(tab_id);
      else await browser.tabs.goForward(tab_id);
      return tab_id;
    }, timeout_ms);
  },

  async reload({ tab_id, timeout_ms = DEFAULT_LOAD_TIMEOUT_MS }) {
    return navigateAndWait(async () => {
      await browser.tabs.reload(tab_id);
      return tab_id;
    }, timeout_ms);
  },

  async activate_tab({ tab_id }) {
    const tab = await browser.tabs.update(tab_id, { active: true });
    await browser.windows.update(tab.windowId, { focused: true });
    return tabInfo(tab);
  },

  async close_tab({ tab_id }) {
    await browser.tabs.remove(tab_id);
    return { closed: tab_id };
  },

  async snapshot({ tab_id, max_elements = 300 }) {
    return pageCall(tab_id, "snapshot", { max_elements });
  },

  async text({ tab_id, max_length = 20000 }) {
    return pageCall(tab_id, "text", { max_length });
  },

  async click({ tab_id, ref }) {
    return pageCall(tab_id, "click", { ref });
  },

  async fill({ tab_id, ref, value }) {
    return pageCall(tab_id, "fill", { ref, value });
  },

  async press_key({ tab_id, key, ref = null }) {
    return pageCall(tab_id, "pressKey", { key, ref });
  },

  async evaluate({ tab_id, code }) {
    // The body runs as an async function in the isolated content-script
    // world; the JSON round trip turns DOM nodes etc. into a clear error
    // instead of a structured-clone failure.
    const [result] = await browser.tabs.executeScript(tab_id, {
      code: `(async () => { ${code}\n})().then((v) => JSON.stringify(v === undefined ? null : v))`,
    });
    return JSON.parse(result);
  },

  async screenshot({ tab_id }) {
    return browser.tabs.captureTab(tab_id, { format: "png" });
  },
};

connect();
