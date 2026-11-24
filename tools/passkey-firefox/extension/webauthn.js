// passkey-firefox, authenticator helpers without browser APIs (background.js uses them, the
// tests load them in node): CBOR, the passkey file format, P-256 public keys, signatures,
// authenticatorData and the RP ID check.
"use strict";

// ---- bytes ----------------------------------------------------------------------------------

function b64u(data) {
  var text = "";
  for (var i = 0; i < data.length; i++) text += String.fromCharCode(data[i]);
  return btoa(text).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}

function fromB64u(text) {
  return Uint8Array.from(
    atob(text.replace(/-/g, "+").replace(/_/g, "/")),
    function (c) {
      return c.charCodeAt(0);
    },
  );
}

function hex(data) {
  return Array.from(data, function (b) {
    return b.toString(16).padStart(2, "0");
  }).join("");
}

function concat() {
  var parts = Array.from(arguments);
  var out = new Uint8Array(parts.reduce((n, p) => n + p.length, 0));
  parts.reduce((at, p) => (out.set(p, at), at + p.length), 0);
  return out;
}

function equal(a, b) {
  return a.length === b.length && a.every((x, i) => x === b[i]);
}

// ---- CBOR (RFC 8949): the subset passkey files, COSE keys and attestation objects use -------
// Maps are encoded from plain objects (text keys) or Map (any keys) in insertion order and
// decoded into plain objects.

function cborEncode(value) {
  var out = [];
  function head(major, n) {
    if (n < 24) out.push((major << 5) | n);
    else if (n < 0x100) out.push((major << 5) | 24, n);
    else if (n < 0x10000) out.push((major << 5) | 25, n >> 8, n & 0xff);
    else if (n < 0x100000000)
      out.push(
        (major << 5) | 26,
        n >>> 24,
        (n >> 16) & 0xff,
        (n >> 8) & 0xff,
        n & 0xff,
      );
    else {
      out.push((major << 5) | 27);
      for (var i = 7; i >= 0; i--)
        out.push(Number((BigInt(n) >> BigInt(8 * i)) & 0xffn));
    }
  }
  function item(v) {
    if (v === null || v === undefined) out.push(0xf6);
    else if (v === false || v === true) out.push(v ? 0xf5 : 0xf4);
    else if (typeof v === "number") {
      if (!Number.isSafeInteger(v))
        throw new TypeError("CBOR: not an integer: " + v);
      v < 0 ? head(1, -1 - v) : head(0, v);
    } else if (typeof v === "string") {
      var text = new TextEncoder().encode(v);
      head(3, text.length);
      text.forEach((b) => out.push(b));
    } else if (v instanceof Uint8Array) {
      head(2, v.length);
      v.forEach((b) => out.push(b));
    } else if (Array.isArray(v)) {
      head(4, v.length);
      v.forEach(item);
    } else {
      var entries = v instanceof Map ? Array.from(v) : Object.entries(v);
      head(5, entries.length);
      entries.forEach(([k, x]) => (item(k), item(x)));
    }
  }
  item(value);
  return Uint8Array.from(out);
}

function cborDecode(data) {
  var at = 0;
  function uint(info) {
    if (info < 24) return info;
    var size = { 24: 1, 25: 2, 26: 4, 27: 8 }[info];
    if (!size || at + size > data.length) throw new Error("CBOR: bad length");
    var n = 0n;
    for (var i = 0; i < size; i++) n = (n << 8n) | BigInt(data[at++]);
    if (n > BigInt(Number.MAX_SAFE_INTEGER))
      throw new Error("CBOR: integer too large");
    return Number(n);
  }
  function item() {
    if (at >= data.length) throw new Error("CBOR: truncated");
    var first = data[at++];
    var major = first >> 5;
    var info = first & 0x1f;
    if (major === 7) {
      if (info === 20 || info === 21) return info === 21;
      if (info === 22) return null;
      throw new Error("CBOR: unsupported simple value or float " + info);
    }
    var n = uint(info);
    if (major === 0) return n;
    if (major === 1) return -1 - n;
    if (major === 2 || major === 3) {
      if (at + n > data.length) throw new Error("CBOR: truncated");
      var raw = data.slice(at, (at += n));
      return major === 2
        ? raw
        : new TextDecoder("utf-8", { fatal: true }).decode(raw);
    }
    if (major === 4) return Array.from({ length: n }, item);
    if (major === 5) {
      var map = {};
      for (var i = 0; i < n; i++) {
        var key = item();
        map[key] = item();
      }
      return map;
    }
    throw new Error("CBOR: unsupported major type " + major);
  }
  var value = item();
  if (at !== data.length) throw new Error("CBOR: trailing bytes");
  return value;
}

// ---- passkey files --------------------------------------------------------------------------
// The CBOR map passless (storage/credential.rs) and the Android app read and write. Byte fields
// are arrays of uint; readers also take byte strings. public_key (Android only) is ignored.

function bytesField(v) {
  if (v instanceof Uint8Array) return v;
  if (
    Array.isArray(v) &&
    v.every((b) => Number.isInteger(b) && b >= 0 && b < 256)
  )
    return Uint8Array.from(v);
  throw new Error("passkey file: expected bytes");
}

function encodePasskey(c) {
  return cborEncode({
    id: Array.from(c.id),
    rp: { id: c.rp.id, name: c.rp.name ?? null },
    user: {
      id: Array.from(c.user.id),
      name: c.user.name ?? null,
      display_name: c.user.displayName ?? null,
    },
    sign_count: c.signCount,
    alg: -7,
    private_key: Array.from(c.privateKey),
    key_provider: null,
    key_format_version: null,
    created: c.created,
    discoverable: true,
    backup_state: "eligible",
    extensions: { cred_protect: null, hmac_secret: null },
  });
}

function decodePasskey(data) {
  var m = cborDecode(data);
  var key = bytesField(m.private_key);
  if (key.length > 32) throw new Error("passkey file: private key too long");
  return {
    id: bytesField(m.id),
    rp: { id: m.rp.id, name: m.rp.name ?? null },
    user: {
      id: bytesField(m.user.id),
      name: m.user.name ?? null,
      displayName: m.user.display_name ?? null,
    },
    signCount: m.sign_count,
    alg: m.alg,
    privateKey: concat(new Uint8Array(32 - key.length), key),
    created: m.created,
    discoverable: m.discoverable !== false,
    backupEligible: m.backup_state !== "notEligible",
  };
}

// ---- P-256 --------------------------------------------------------------------------------
// WebCrypto imports a private key only together with its public point (Firefox's PKCS#8 import
// of a bare scalar never settles), passless files hold only the scalar: derive the point.

var P = 2n ** 256n - 2n ** 224n + 2n ** 192n + 2n ** 96n - 1n;
var G = [
  0x6b17d1f2e12c4247f8bce6e563a440f277037d812deb33a0f4a13945d898c296n,
  0x4fe342e2fe1a7f9b8ee7eb4a7c0f9e162bce33576b315ececbb6406837bf51f5n,
];

function mod(a) {
  a %= P;
  return a < 0n ? a + P : a;
}

function inverse(a) {
  var t = 0n,
    nt = 1n,
    r = P,
    nr = mod(a);
  while (nr) {
    var q = r / nr;
    [t, nt] = [nt, t - q * nt];
    [r, nr] = [nr, r - q * nr];
  }
  return mod(t);
}

function add(p, q) {
  if (!p) return q;
  if (!q) return p;
  var l;
  if (p[0] === q[0]) {
    if (mod(p[1] + q[1]) === 0n) return null;
    l = mod((3n * p[0] * p[0] - 3n) * inverse(2n * p[1]));
  } else {
    l = mod((q[1] - p[1]) * inverse(q[0] - p[0]));
  }
  var x = mod(l * l - p[0] - q[0]);
  return [x, mod(l * (p[0] - x) - p[1])];
}

function bigBytes(n) {
  return Uint8Array.from(n.toString(16).padStart(64, "0").match(/../g), (h) =>
    parseInt(h, 16),
  );
}

// JWK of the private key `d` (32 bytes), with the public point.
function privateJwk(d) {
  var point = null;
  for (var k = BigInt("0x" + hex(d)), q = G; k; k >>= 1n, q = add(q, q))
    if (k & 1n) point = add(point, q);
  return {
    kty: "EC",
    crv: "P-256",
    d: b64u(d),
    x: b64u(bigBytes(point[0])),
    y: b64u(bigBytes(point[1])),
    ext: true,
  };
}

// COSE_Key (RFC 9053) of an ES256 public key, from its JWK.
function coseKey(jwk) {
  return cborEncode(
    new Map([
      [1, 2],
      [3, -7],
      [-1, 1],
      [-2, fromB64u(jwk.x)],
      [-3, fromB64u(jwk.y)],
    ]),
  );
}

// WebCrypto's ECDSA signature (r || s) as the DER sequence WebAuthn wants.
function derSignature(raw) {
  function integer(b) {
    var i = 0;
    while (i < b.length - 1 && b[i] === 0 && !(b[i + 1] & 0x80)) i++;
    b = b.subarray(i);
    return b[0] & 0x80 ? [0x02, b.length + 1, 0, ...b] : [0x02, b.length, ...b];
  }
  var r = integer(raw.subarray(0, 32));
  var s = integer(raw.subarray(32));
  return Uint8Array.from([0x30, r.length + s.length, ...r, ...s]);
}

// ---- authenticatorData (WebAuthn §6.1) ----------------------------------------------------
// Flags: UP, UV (the decrypt by `pass` verifies the user), BE/BS (the store is a synced git repo),
// AT with attested credential data. The signature counter is always 0, as the Android app does for
// synced stores (its default "zero signature counter").

function authenticatorData(rpIdHash, backupEligible, credentialId, cose) {
  var flags = 0x01 | 0x04 | (backupEligible ? 0x18 : 0) | (cose ? 0x40 : 0);
  var head = concat(rpIdHash, Uint8Array.of(flags, 0, 0, 0, 0));
  if (!cose) return head;
  return concat(
    head,
    new Uint8Array(16),
    Uint8Array.of(credentialId.length >> 8, credentialId.length & 0xff),
    credentialId,
    cose,
  );
}

// ---- RP ID check (WebAuthn §5.1.3/§5.1.4 with the public suffix list) ---------------------

function parseSuffixList(text) {
  var rules = new Set();
  text.split("\n").forEach(function (line) {
    var rule = line.trim().split(/\s/)[0];
    if (!rule || rule.startsWith("//")) return;
    var prefix = rule.match(/^(!|\*\.)?/)[0];
    try {
      rules.add(
        prefix + new URL("http://" + rule.slice(prefix.length)).hostname,
      );
    } catch (e) {
      rules.add(rule);
    }
  });
  return rules;
}

function isPublicSuffix(name, rules) {
  if (rules.has("!" + name)) return false;
  var dot = name.indexOf(".");
  return dot < 0 || rules.has(name) || rules.has("*." + name.slice(dot + 1));
}

// May a page on `host` use `rpId`? Its own host, or a parent domain that is not a public suffix.
function rpIdAllowed(host, rpId, rules) {
  if (rpId === host) return true;
  if (/^[0-9.]+$|^\[/.test(host) || !host.endsWith("." + rpId)) return false;
  return !isPublicSuffix(rpId, rules);
}

// Origins WebAuthn works on: https, and http for localhost.
function secureOrigin(url) {
  try {
    var u = new URL(url);
    var local = u.hostname === "localhost" || u.hostname.endsWith(".localhost");
    return u.protocol === "https:" || (u.protocol === "http:" && local)
      ? u
      : null;
  } catch (e) {
    return null;
  }
}

if (typeof module !== "undefined") {
  module.exports = {
    b64u,
    fromB64u,
    hex,
    concat,
    equal,
    cborEncode,
    cborDecode,
    encodePasskey,
    decodePasskey,
    privateJwk,
    coseKey,
    derSignature,
    authenticatorData,
    parseSuffixList,
    isPublicSuffix,
    rpIdAllowed,
    secureOrigin,
  };
}
