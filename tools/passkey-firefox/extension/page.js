// passkey-firefox, page world: replaces navigator.credentials.create/get for public-key requests.
//
// Firefox has no API that lets an extension answer WebAuthn, so (as KeePassXC-Browser and
// Bitwarden do) this script runs in the page before the page's own scripts and overrides
// CredentialsContainer. A request is serialized to WebAuthn JSON and posted to bridge.js (the
// extension's content script in this frame), which passes it to background.js, the
// authenticator. The answer, a PublicKeyCredential.toJSON() object, becomes a
// PublicKeyCredential again.
//
// Nothing here is trusted: the page can call or replace these functions. The origin of a request
// is taken by background.js from the browser (the sender of the bridge's message), and
// background.js builds clientDataJSON and checks the RP ID itself.
(function () {
  "use strict";

  var REQUEST = "passkey-firefox-request:";
  var ABORT = "passkey-firefox-abort:";
  var RESULT = "passkey-firefox-result:";

  var nativeCreate = CredentialsContainer.prototype.create;
  var nativeGet = CredentialsContainer.prototype.get;
  var pending = new Map();
  var nextId = 1;

  // ---- encoding ----------------------------------------------------------------------------

  function bytes(source) {
    if (source instanceof ArrayBuffer) return new Uint8Array(source);
    if (ArrayBuffer.isView(source))
      return new Uint8Array(
        source.buffer,
        source.byteOffset,
        source.byteLength,
      );
    throw new TypeError("expected a BufferSource");
  }

  function b64u(source) {
    var data = bytes(source);
    var text = "";
    for (var i = 0; i < data.length; i++) text += String.fromCharCode(data[i]);
    return btoa(text)
      .replace(/\+/g, "-")
      .replace(/\//g, "_")
      .replace(/=+$/, "");
  }

  function buffer(text) {
    var binary = atob(text.replace(/-/g, "+").replace(/_/g, "/"));
    var data = new Uint8Array(binary.length);
    for (var i = 0; i < binary.length; i++) data[i] = binary.charCodeAt(i);
    return data.buffer;
  }

  function descriptors(list) {
    return Array.from(list || [], function (d) {
      var out = { type: d.type, id: b64u(d.id) };
      if (d.transports) out.transports = Array.from(d.transports);
      return out;
    });
  }

  // The client extension inputs that are plain JSON values; background.js ignores what it does not know.
  function extensions(inputs) {
    var out = {};
    Object.keys(inputs || {}).forEach(function (name) {
      var value = inputs[name];
      if (["boolean", "string", "number"].indexOf(typeof value) !== -1)
        out[name] = value;
    });
    return out;
  }

  function creationJSON(pk) {
    return {
      rp: { id: pk.rp.id, name: pk.rp.name },
      user: {
        id: b64u(pk.user.id),
        name: pk.user.name,
        displayName: pk.user.displayName,
      },
      challenge: b64u(pk.challenge),
      pubKeyCredParams: Array.from(pk.pubKeyCredParams || [], function (p) {
        return { type: p.type, alg: p.alg };
      }),
      timeout: pk.timeout,
      excludeCredentials: descriptors(pk.excludeCredentials),
      authenticatorSelection: pk.authenticatorSelection,
      attestation: pk.attestation,
      extensions: extensions(pk.extensions),
    };
  }

  function requestJSON(pk) {
    return {
      challenge: b64u(pk.challenge),
      timeout: pk.timeout,
      rpId: pk.rpId,
      allowCredentials: descriptors(pk.allowCredentials),
      userVerification: pk.userVerification,
      extensions: extensions(pk.extensions),
    };
  }

  // ---- the credential the page gets ---------------------------------------------------------

  function define(object, values) {
    Object.keys(values).forEach(function (name) {
      Object.defineProperty(object, name, {
        value: values[name],
        enumerable: true,
      });
    });
    return object;
  }

  function copy(json) {
    return JSON.parse(JSON.stringify(json));
  }

  function credential(op, json) {
    var r = json.response;
    var response;
    if (op === "create") {
      response = define(
        Object.create(AuthenticatorAttestationResponse.prototype),
        {
          clientDataJSON: buffer(r.clientDataJSON),
          attestationObject: buffer(r.attestationObject),
          getTransports: function () {
            return (r.transports || []).slice();
          },
          getAuthenticatorData: function () {
            return buffer(r.authenticatorData);
          },
          getPublicKey: function () {
            return r.publicKey ? buffer(r.publicKey) : null;
          },
          getPublicKeyAlgorithm: function () {
            return r.publicKeyAlgorithm;
          },
          toJSON: function () {
            return copy(r);
          },
        },
      );
    } else {
      response = define(
        Object.create(AuthenticatorAssertionResponse.prototype),
        {
          clientDataJSON: buffer(r.clientDataJSON),
          authenticatorData: buffer(r.authenticatorData),
          signature: buffer(r.signature),
          userHandle: r.userHandle ? buffer(r.userHandle) : null,
          toJSON: function () {
            return copy(r);
          },
        },
      );
    }
    return define(Object.create(PublicKeyCredential.prototype), {
      id: json.id,
      rawId: buffer(json.rawId),
      type: json.type,
      response: response,
      authenticatorAttachment: json.authenticatorAttachment,
      getClientExtensionResults: function () {
        return copy(json.clientExtensionResults || {});
      },
      toJSON: function () {
        return copy(json);
      },
    });
  }

  // ---- talking to the bridge ----------------------------------------------------------------

  window.addEventListener("message", function (event) {
    if (
      event.source !== window ||
      typeof event.data !== "string" ||
      event.data.indexOf(RESULT) !== 0
    )
      return;
    var message;
    try {
      message = JSON.parse(event.data.slice(RESULT.length));
    } catch (e) {
      return;
    }
    var settle = pending.get(message.id);
    if (settle) settle(message);
  });

  function relay(op, body, signal, timeout) {
    return new Promise(function (resolve, reject) {
      var id = nextId++;
      var timer = null;
      function finish() {
        pending.delete(id);
        clearTimeout(timer);
        if (signal) signal.removeEventListener("abort", onAbort);
      }
      function cancel(error) {
        finish();
        window.postMessage(ABORT + JSON.stringify({ id: id }), "*");
        reject(error);
      }
      function onAbort() {
        cancel(
          signal.reason !== undefined
            ? signal.reason
            : new DOMException("The operation was aborted.", "AbortError"),
        );
      }
      pending.set(id, function (message) {
        finish();
        resolve(message);
      });
      if (signal) signal.addEventListener("abort", onAbort);
      if (typeof timeout === "number" && timeout > 0) {
        timer = setTimeout(
          function () {
            cancel(
              new DOMException(
                "The operation either timed out or was not allowed.",
                "NotAllowedError",
              ),
            );
          },
          Math.max(timeout, 30000),
        );
      }
      window.postMessage(
        REQUEST +
          JSON.stringify({ id: id, op: op, body: JSON.stringify(body) }),
        "*",
      );
    });
  }

  function run(op, container, options, nativeCall) {
    var pk = options.publicKey;
    var signal = options.signal;
    if (signal && signal.aborted) {
      return Promise.reject(
        signal.reason !== undefined
          ? signal.reason
          : new DOMException("The operation was aborted.", "AbortError"),
      );
    }
    var body;
    try {
      body = op === "create" ? creationJSON(pk) : requestJSON(pk);
    } catch (e) {
      return Promise.reject(
        e instanceof TypeError ? e : new TypeError(String(e)),
      );
    }
    return relay(op, body, signal, pk.timeout).then(function (message) {
      // No native host installed: the browser's own WebAuthn (security keys) answers.
      if (message.unavailable) return nativeCall.call(container, options);
      if (message.ok) return credential(op, JSON.parse(message.body));
      throw new DOMException(
        message.message || "The operation either timed out or was not allowed.",
        message.dom || "NotAllowedError",
      );
    });
  }

  CredentialsContainer.prototype.create = function create(options) {
    if (!options || !options.publicKey) return nativeCreate.call(this, options);
    return run("create", this, options, nativeCreate);
  };

  CredentialsContainer.prototype.get = function get(options) {
    // Passkey autofill (conditional mediation) needs browser UI; it stays with the browser.
    if (!options || !options.publicKey || options.mediation === "conditional")
      return nativeGet.call(this, options);
    return run("get", this, options, nativeGet);
  };

  // Every sign-in decrypts with the hardware key behind `pass`, so sites may offer passkeys.
  PublicKeyCredential.isUserVerifyingPlatformAuthenticatorAvailable =
    function () {
      return Promise.resolve(true);
    };
  PublicKeyCredential.isConditionalMediationAvailable = function () {
    return Promise.resolve(false);
  };
})();
