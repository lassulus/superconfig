/* Browser MCP content-side helpers.
 *
 * Injected on demand into the extension's isolated content-script world of a
 * page. Element refs are kept here (not as DOM attributes), so the page cannot
 * observe them; they live as long as the document.
 */

// eslint-disable-next-line no-var
var __browserMcp = (() => {
  const refs = new Map(); // ref -> WeakRef(element)
  const elementRefs = new WeakMap(); // element -> ref
  let nextRef = 1;

  const INTERACTIVE = [
    "a[href]",
    "button",
    "input:not([type=hidden])",
    "select",
    "textarea",
    "summary",
    "[contenteditable=''], [contenteditable=true]",
    "[role=button], [role=link], [role=checkbox], [role=radio], [role=switch]",
    "[role=tab], [role=menuitem], [role=menuitemcheckbox], [role=option]",
    "[role=combobox], [role=textbox], [role=searchbox], [role=slider]",
    "[tabindex]:not([tabindex='-1'])",
    "[onclick]",
  ].join(", ");
  const HEADINGS = "h1, h2, h3, h4, h5, h6";

  function refFor(el) {
    let ref = elementRefs.get(el);
    if (ref === undefined) {
      ref = nextRef++;
      elementRefs.set(el, ref);
      refs.set(ref, new WeakRef(el));
    }
    return ref;
  }

  function lookup(ref) {
    const el = refs.get(ref)?.deref();
    if (!el || !el.isConnected) {
      throw new Error(`ref ${ref} is gone; take a new snapshot`);
    }
    return el;
  }

  function clip(s, n) {
    s = (s || "").replace(/\s+/g, " ").trim();
    return s.length > n ? s.slice(0, n - 1) + "…" : s;
  }

  function accessibleName(el) {
    const labelledby = el.getAttribute("aria-labelledby");
    if (labelledby) {
      const text = labelledby
        .split(/\s+/)
        .map((id) => document.getElementById(id)?.innerText || "")
        .join(" ");
      if (text.trim()) return text;
    }
    const direct =
      el.getAttribute("aria-label") ||
      (el.labels && [...el.labels].map((l) => l.innerText).join(" "));
    if (direct && direct.trim()) return direct;
    if (el.tagName === "INPUT" || el.tagName === "TEXTAREA") {
      return el.placeholder || el.title || "";
    }
    return (
      el.innerText ||
      el.getAttribute("title") ||
      el.getAttribute("alt") ||
      el.querySelector?.("img[alt]")?.alt ||
      ""
    );
  }

  function roleOf(el) {
    const role = el.getAttribute("role");
    if (role) return role;
    const tag = el.tagName.toLowerCase();
    if (tag === "a") return "link";
    if (tag === "input") return `input[${el.type}]`;
    if (/^h[1-6]$/.test(tag)) return `heading${tag[1]}`;
    if (el.isContentEditable) return "editable";
    return tag;
  }

  function visible(el) {
    if (
      el.checkVisibility &&
      !el.checkVisibility({ visibilityProperty: true })
    ) {
      return false;
    }
    const r = el.getBoundingClientRect();
    return r.width > 0 && r.height > 0;
  }

  // Walks the document and open shadow roots in document order.
  function* walk(root) {
    for (const el of root.querySelectorAll("*")) {
      yield el;
      if (el.shadowRoot) yield* walk(el.shadowRoot);
    }
  }

  function describe(el) {
    const parts = [`[${refFor(el)}]`, roleOf(el)];
    const name = clip(accessibleName(el), 80);
    if (name) parts.push(JSON.stringify(name));
    const tag = el.tagName;
    if (tag === "INPUT" && (el.type === "checkbox" || el.type === "radio")) {
      parts.push(el.checked ? "checked" : "unchecked");
    } else if (tag === "INPUT" || tag === "TEXTAREA" || tag === "SELECT") {
      if (el.value) parts.push(`value=${JSON.stringify(clip(el.value, 80))}`);
    }
    if (tag === "A") parts.push(`-> ${clip(el.getAttribute("href"), 100)}`);
    if (el.disabled) parts.push("disabled");
    return parts.join(" ");
  }

  function snapshot({ max_elements }) {
    const lines = [];
    let total = 0;
    for (const el of walk(document)) {
      if (!el.matches(INTERACTIVE) && !el.matches(HEADINGS)) continue;
      if (!visible(el)) continue;
      total++;
      if (lines.length < max_elements) lines.push(describe(el));
    }
    const header = [`title: ${document.title}`, `url: ${location.href}`];
    if (total > lines.length) {
      header.push(`(showing ${lines.length} of ${total} elements)`);
    }
    return [...header, "", ...lines].join("\n");
  }

  function text({ max_length }) {
    const t = document.body ? document.body.innerText : "";
    return t.length > max_length
      ? t.slice(0, max_length) + `\n… (${t.length - max_length} more chars)`
      : t;
  }

  function mouse(el, type, x, y) {
    const Ctor = type.startsWith("pointer") ? PointerEvent : MouseEvent;
    el.dispatchEvent(
      new Ctor(type, {
        bubbles: true,
        cancelable: true,
        composed: true,
        clientX: x,
        clientY: y,
        button: 0,
        buttons: type.endsWith("down") ? 1 : 0,
        view: window,
      }),
    );
  }

  function click({ ref }) {
    const el = lookup(ref);
    el.scrollIntoView({ block: "center", inline: "center" });
    const r = el.getBoundingClientRect();
    const x = r.left + r.width / 2;
    const y = r.top + r.height / 2;
    mouse(el, "pointerdown", x, y);
    mouse(el, "mousedown", x, y);
    el.focus?.({ preventScroll: true });
    mouse(el, "pointerup", x, y);
    mouse(el, "mouseup", x, y);
    el.click();
    return `clicked ${describe(el)}`;
  }

  function fill({ ref, value }) {
    const el = lookup(ref);
    el.scrollIntoView({ block: "center" });
    el.focus();
    if (el.tagName === "SELECT") {
      const option = [...el.options].find(
        (o) => o.value === value || o.text.trim() === value,
      );
      if (!option) throw new Error(`no option ${JSON.stringify(value)}`);
      el.value = option.value;
    } else if (
      el.tagName === "INPUT" &&
      (el.type === "checkbox" || el.type === "radio")
    ) {
      const want = value === "true" || value === "on" || value === "checked";
      if (el.checked !== want) el.click();
      return `set ${describe(el)}`;
    } else {
      // insertText goes through the editor like real typing (trusted input
      // events, works for frameworks and contenteditable editors).
      if (el.select) el.select();
      else document.getSelection().selectAllChildren(el);
      const inserted =
        value === ""
          ? document.execCommand("delete")
          : document.execCommand("insertText", false, value);
      if (!inserted) {
        if (el.isContentEditable) el.textContent = value;
        else el.value = value;
        el.dispatchEvent(new Event("input", { bubbles: true, composed: true }));
      }
    }
    el.dispatchEvent(new Event("change", { bubbles: true }));
    return `filled ${describe(el)}`;
  }

  const KEY_CODES = {
    Enter: 13,
    Escape: 27,
    Tab: 9,
    Backspace: 8,
    Delete: 46,
    ArrowUp: 38,
    ArrowDown: 40,
    ArrowLeft: 37,
    ArrowRight: 39,
    " ": 32,
  };

  function pressKey({ key, ref }) {
    const el =
      ref == null ? document.activeElement || document.body : lookup(ref);
    const init = {
      key,
      code: key.length === 1 ? `Key${key.toUpperCase()}` : key,
      keyCode:
        KEY_CODES[key] ||
        (key.length === 1 ? key.toUpperCase().charCodeAt(0) : 0),
      bubbles: true,
      cancelable: true,
      composed: true,
    };
    const notCancelled = el.dispatchEvent(new KeyboardEvent("keydown", init));
    if (key.length === 1 || key === "Enter") {
      el.dispatchEvent(new KeyboardEvent("keypress", init));
    }
    el.dispatchEvent(new KeyboardEvent("keyup", init));
    // Synthetic key events have no default action; do the one that matters.
    if (notCancelled && key === "Enter" && el.form && el.tagName === "INPUT") {
      el.form.requestSubmit();
      return `pressed Enter on ${describe(el)}, submitted form`;
    }
    return `pressed ${key} on ${describe(el)}`;
  }

  return { snapshot, text, click, fill, pressKey };
})();
