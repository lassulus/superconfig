// passkey-firefox, background: the authenticator. Answers navigator.credentials.create/get
// (relayed by page.js and bridge.js) with the passkeys of the passage store, which the native
// host passkey_firefox lists, decrypts and writes through `pass`.
//
// The origin is the URL of the frame the browser says sent the request, never anything the page
// wrote. Signing in decrypts one passkey file: `pass` asks the hardware key, that is the user's
// approval. Registering encrypts only, so the page shows a confirm() first.
//
// Without the host, without a passkey of the site in the store, or when the user cancels, the
// browser's own WebAuthn (security keys) answers instead.
"use strict";

var HOST = "passkey_firefox";
var requests = new Map(); // "<tab>:<frame>:<page id>" -> {aborted}
var FALLBACK = { unavailable: true };

function fail(name, message) {
  return new DOMException(
    message || "The operation either timed out or was not allowed.",
    name,
  );
}

function host(message) {
  return browser.runtime.sendNativeMessage(HOST, message).then(
    function (reply) {
      if (reply.error)
        throw fail("NotAllowedError", "passkey_firefox: " + reply.error);
      return reply;
    },
    function (e) {
      if (/no such native application/i.test(e.message)) throw FALLBACK;
      throw fail("NotAllowedError", "passkey_firefox: " + e.message);
    },
  );
}

var suffixes = null;
function publicSuffixes() {
  suffixes =
    suffixes ||
    fetch("public_suffix_list.dat")
      .then((r) => r.text())
      .then(parseSuffixList);
  return suffixes;
}

async function sha256(data) {
  return new Uint8Array(await crypto.subtle.digest("SHA-256", data));
}

// The page's choice of RP ID, checked against the frame's host.
async function relyingParty(url, rpId) {
  rpId = rpId === undefined ? url.hostname : String(rpId);
  if (!rpIdAllowed(url.hostname, rpId, await publicSuffixes()))
    throw fail("SecurityError", "The RP ID is not allowed for this origin.");
  return rpId;
}

function clientData(type, challenge, url) {
  var json = JSON.stringify({
    type: type,
    challenge: challenge,
    origin: url.origin,
    crossOrigin: false,
  });
  return new TextEncoder().encode(json);
}

// A confirm() in the requesting frame (as the extension, out of the page's reach).
async function ask(sender, question) {
  var results = await browser.scripting.executeScript({
    target: { tabId: sender.tab.id, frameIds: [sender.frameId] },
    func: (q) => window.confirm(q),
    args: [question],
  });
  return results[0] && results[0].result === true;
}

async function create(sender, url, pk, live) {
  var rpId = await relyingParty(url, pk.rp.id);
  var algs = (pk.pubKeyCredParams || []).map((p) => p.alg);
  if (algs.length && !algs.includes(-7))
    throw fail("NotSupportedError", "Only ES256 passkeys are supported.");
  var existing = (await host({ op: "list", rp: rpId })).names;
  if (
    (pk.excludeCredentials || []).some((d) =>
      existing.includes("passkey-" + hex(fromB64u(d.id).subarray(0, 4))),
    )
  ) {
    throw fail(
      "InvalidStateError",
      "A passkey of this account is already stored.",
    );
  }
  live();
  var question =
    "Create a passkey for " +
    rpId +
    ' as "' +
    pk.user.name +
    '" in the passage store?';
  if (
    !(await ask(
      sender,
      question + "\n\nCancel: the browser's own WebAuthn (security key).",
    ))
  )
    throw FALLBACK;
  live();

  var pair = await crypto.subtle.generateKey(
    { name: "ECDSA", namedCurve: "P-256" },
    true,
    ["sign"],
  );
  var jwk = await crypto.subtle.exportKey("jwk", pair.privateKey);
  var id = crypto.getRandomValues(new Uint8Array(32));
  var file = encodePasskey({
    id: id,
    rp: { id: rpId, name: pk.rp.name },
    user: {
      id: fromB64u(pk.user.id),
      name: pk.user.name,
      displayName: pk.user.displayName,
    },
    signCount: 0,
    privateKey: fromB64u(jwk.d),
    created: Math.floor(Date.now() / 1000),
  });
  await host({
    op: "write",
    rp: rpId,
    id: hex(id.subarray(0, 4)),
    data: btoa(String.fromCharCode(...file)),
  });

  var authData = authenticatorData(
    await sha256(new TextEncoder().encode(rpId)),
    true,
    id,
    coseKey(jwk),
  );
  var spki = new Uint8Array(
    await crypto.subtle.exportKey("spki", pair.publicKey),
  );
  return {
    id: b64u(id),
    rawId: b64u(id),
    type: "public-key",
    authenticatorAttachment: "platform",
    response: {
      clientDataJSON: b64u(clientData("webauthn.create", pk.challenge, url)),
      attestationObject: b64u(
        cborEncode({ fmt: "none", attStmt: {}, authData: authData }),
      ),
      authenticatorData: b64u(authData),
      publicKey: b64u(spki),
      publicKeyAlgorithm: -7,
      transports: ["internal"],
    },
    clientExtensionResults:
      pk.extensions && pk.extensions.credProps
        ? { credProps: { rk: true } }
        : {},
  };
}

async function get(sender, url, pk, live) {
  var rpId = await relyingParty(url, pk.rpId);
  var names = (await host({ op: "list", rp: rpId })).names;
  var allowed = (pk.allowCredentials || []).map((d) => fromB64u(d.id));
  // With allowCredentials only their files (by name) and passkey.age (name says nothing) are read.
  var candidates = allowed.length
    ? allowed
        .map((id) => "passkey-" + hex(id.subarray(0, 4)))
        .concat("passkey")
        .filter((n) => names.includes(n))
    : names;
  candidates = Array.from(new Set(candidates));

  for (var name of candidates) {
    live();
    var reply = await host({ op: "read", rp: rpId, name: name });
    var cred = decodePasskey(
      Uint8Array.from(atob(reply.data), (c) => c.charCodeAt(0)),
    );
    live();
    if (cred.rp.id !== rpId || cred.alg !== -7) continue;
    if (
      allowed.length
        ? !allowed.some((id) => equal(id, cred.id))
        : !cred.discoverable
    )
      continue;
    // Without allowCredentials and several accounts the user picks one, account by account.
    var label = cred.user.name || cred.user.displayName || name;
    if (
      !allowed.length &&
      candidates.length > 1 &&
      !(await ask(sender, "Sign in to " + rpId + ' as "' + label + '"?'))
    )
      continue;

    var key = await crypto.subtle.importKey(
      "jwk",
      privateJwk(cred.privateKey),
      { name: "ECDSA", namedCurve: "P-256" },
      false,
      ["sign"],
    );
    var authData = authenticatorData(
      await sha256(new TextEncoder().encode(rpId)),
      cred.backupEligible,
    );
    var cdj = clientData("webauthn.get", pk.challenge, url);
    var signed = concat(authData, await sha256(cdj));
    var raw = new Uint8Array(
      await crypto.subtle.sign({ name: "ECDSA", hash: "SHA-256" }, key, signed),
    );
    return {
      id: b64u(cred.id),
      rawId: b64u(cred.id),
      type: "public-key",
      authenticatorAttachment: "platform",
      response: {
        clientDataJSON: b64u(cdj),
        authenticatorData: b64u(authData),
        signature: b64u(derSignature(raw)),
        userHandle: b64u(cred.user.id),
      },
      clientExtensionResults: {},
    };
  }
  throw FALLBACK;
}

browser.runtime.onMessage.addListener(function (msg, sender) {
  if (
    sender.id !== browser.runtime.id ||
    !sender.tab ||
    !msg ||
    typeof msg.id !== "number"
  )
    return;
  var key = sender.tab.id + ":" + sender.frameId + ":" + msg.id;
  if (msg.type === "abort") {
    if (requests.has(key)) requests.get(key).aborted = true;
    return;
  }
  if (
    msg.type !== "request" ||
    (msg.op !== "create" && msg.op !== "get") ||
    typeof msg.body !== "string"
  )
    return;
  var state = { aborted: false };
  requests.set(key, state);
  function live() {
    if (state.aborted) throw fail("AbortError", "The operation was aborted.");
  }

  var url = secureOrigin(sender.url);
  // Frames of another origin than the tab's are refused (they would need the
  // publickey-credentials-* permissions policy, which this add-on cannot see).
  var crossOrigin =
    !url ||
    (sender.frameId !== 0 &&
      (secureOrigin(sender.tab.url) || {}).origin !== url.origin);
  return Promise.resolve()
    .then(function () {
      if (crossOrigin) throw fail("NotAllowedError");
      return (msg.op === "create" ? create : get)(
        sender,
        url,
        JSON.parse(msg.body),
        live,
      );
    })
    .then(
      (credential) => ({ ok: true, body: JSON.stringify(credential) }),
      function (e) {
        if (e && e.unavailable) return { unavailable: true };
        if (!(e instanceof DOMException)) console.error("passkey-firefox:", e);
        return {
          ok: false,
          dom: e instanceof DOMException ? e.name : "NotAllowedError",
          message: String(e && e.message),
        };
      },
    )
    .finally(() => requests.delete(key));
});
