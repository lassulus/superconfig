// Unit tests: webauthn.js (CBOR, passkey files, P-256, signatures, authenticatorData, RP ID
// checks) and host.py against a fake `pass`.
// Usage: node unit.mjs <extension dir with public_suffix_list.dat> <host.py>   (python3 on PATH)

import { execFileSync, spawnSync } from "node:child_process";
import {
  createPublicKey,
  generateKeyPairSync,
  verify,
  webcrypto,
} from "node:crypto";
import { createRequire } from "node:module";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";

const [extension, hostPy] = process.argv.slice(2).map((p) => path.resolve(p));
const w = createRequire(import.meta.url)(path.join(extension, "webauthn.js"));
let failed = 0;
function check(ok, what) {
  console.log((ok ? "ok   " : "FAIL ") + what);
  if (!ok) failed++;
}
const hex = (b) => Buffer.from(b).toString("hex");
const unhex = (s) => Uint8Array.from(Buffer.from(s, "hex"));

// ---- CBOR: RFC 8949 appendix A vectors ------------------------------------------------------
for (const [value, expected] of [
  [0, "00"],
  [23, "17"],
  [24, "1818"],
  [100, "1864"],
  [1000, "1903e8"],
  [1000000, "1a000f4240"],
  [4294967296, "1b0000000100000000"],
  [-1, "20"],
  [-1000, "3903e7"],
  ["", "60"],
  ["IETF", "6449455446"],
  ["ü", "62c3bc"],
  [unhex("01020304"), "4401020304"],
  [[1, [2, 3], [4, 5]], "8301820203820405"],
  [{ a: 1, b: [2, 3] }, "a26161016162820203"],
  [false, "f4"],
  [true, "f5"],
  [null, "f6"],
]) {
  const encoded = hex(w.cborEncode(value));
  check(
    encoded === expected,
    `cbor ${JSON.stringify(value instanceof Uint8Array ? hex(value) : value)} -> ${encoded}`,
  );
  const back = w.cborDecode(unhex(expected));
  check(
    JSON.stringify(back) === JSON.stringify(value),
    `cbor ${expected} decodes back`,
  );
}
for (const bad of ["18", "5a0000", "f93c00", "0000", "62c3"]) {
  let threw = false;
  try {
    w.cborDecode(unhex(bad));
  } catch {
    threw = true;
  }
  check(threw, `cbor rejects ${bad}`);
}

// ---- P-256 public keys and signatures -------------------------------------------------------
// The README public keys of the passless and Android fixtures.
for (const [d, pub] of [
  [
    "01080f161d242b323940474e555c636a71787f868d949ba2a9b0b7bec5ccd3da",
    "04eb72df8d977165de80499532a268530cd607775d160ebb588832ff518697656147741e19ab55fe615232386b74224b7ef5fade207808b6cd13731cf5273f6402",
  ],
  [
    "020910171e252c333a41484f565d646b727980878e959ca3aab1b8bfc6cdd4db",
    "04292f85927a8f1f5af272908e0216a273c1d55bf575ec4e11071dfeae1c1316069296c0b17f83a2ca98ee0b8fc8f26609a5b0714bb82e497f054d70075871b970",
  ],
  [
    "202326292c2f3235383b3e4144474a4d505356595c5f6265686b6e7174777a7d",
    "04eb7c35cbf7b34d7db8018803279d74f493fc22d6be39b012e86948d9cab904bdda2bcf30405b8cc1400dd9886d5fbe036be88c26aa27e09a2c13e88bd33d487d",
  ],
]) {
  const jwk = w.privateJwk(unhex(d));
  check(
    "04" + hex(w.fromB64u(jwk.x)) + hex(w.fromB64u(jwk.y)) === pub,
    `public key of ${d.slice(0, 8)}… matches the fixture README`,
  );
}
let keysOk = true,
  sigsOk = true;
for (let i = 0; i < 64; i++) {
  const node = generateKeyPairSync("ec", {
    namedCurve: "P-256",
  }).privateKey.export({ format: "jwk" });
  const jwk = w.privateJwk(w.fromB64u(node.d));
  keysOk &&= jwk.x === node.x && jwk.y === node.y;
  const key = await webcrypto.subtle.importKey(
    "jwk",
    jwk,
    { name: "ECDSA", namedCurve: "P-256" },
    false,
    ["sign"],
  );
  const message = webcrypto.getRandomValues(new Uint8Array(64));
  const raw = new Uint8Array(
    await webcrypto.subtle.sign(
      { name: "ECDSA", hash: "SHA-256" },
      key,
      message,
    ),
  );
  const der = w.derSignature(raw);
  sigsOk &&= verify(
    "sha256",
    message,
    createPublicKey({ key: node, format: "jwk" }),
    der,
  );
}
check(keysOk, "64 random keys: derived public point = node's");
check(sigsOk, "64 random signatures: DER signature verifies (node, DER)");
check(
  hex(w.derSignature(new Uint8Array(64).fill(0x80, 0, 32).fill(0x01, 32))) ===
    "3045022100" + "80".repeat(32) + "0220" + "01".repeat(32),
  "DER: high bit gets a 0x00 prefix",
);
check(
  hex(
    w.derSignature(
      Uint8Array.of(
        ...new Array(31).fill(0),
        0x7f,
        0,
        0,
        ...new Array(30).fill(0x80),
      ),
    ),
  ) ===
    "302402017f021f00" + "80".repeat(30),
  "DER: leading zeros dropped, kept before a high bit",
);

// ---- authenticatorData / COSE / attestation object ------------------------------------------
const jwk = w.privateJwk(
  unhex("01080f161d242b323940474e555c636a71787f868d949ba2a9b0b7bec5ccd3da"),
);
const cose = w.cborDecode(w.coseKey(jwk));
check(
  cose[1] === 2 &&
    cose[3] === -7 &&
    cose[-1] === 1 &&
    hex(cose[-2]) === hex(w.fromB64u(jwk.x)) &&
    hex(cose[-3]) === hex(w.fromB64u(jwk.y)),
  "COSE key: kty EC2, alg ES256, crv P-256, x, y",
);
check(
  hex(w.coseKey(jwk)).startsWith("a501020326200121582"),
  "COSE key: canonical key order 1, 3, -1, -2, -3",
);
const rpIdHash = new Uint8Array(32).fill(7);
const id = new Uint8Array(32).fill(9);
const created = w.authenticatorData(rpIdHash, true, id, w.coseKey(jwk));
check(
  created.length === 37 + 16 + 2 + 32 + 77 && created[32] === 0x5d,
  "registration authData: UP|UV|BE|BS|AT, length",
);
check(
  hex(created.subarray(33, 37)) === "00000000" &&
    hex(created.subarray(37, 53)) === "00".repeat(16),
  "registration authData: counter 0, zero AAGUID",
);
check(
  created[53] === 0 &&
    created[54] === 32 &&
    hex(created.subarray(55, 87)) === hex(id),
  "registration authData: credential id",
);
const assertion = w.authenticatorData(rpIdHash, false);
check(
  assertion.length === 37 && assertion[32] === 0x05,
  "assertion authData of a notEligible passkey: UP|UV, 37 bytes",
);
const att = w.cborDecode(
  w.cborEncode({ fmt: "none", attStmt: {}, authData: created }),
);
check(
  att.fmt === "none" &&
    Object.keys(att.attStmt).length === 0 &&
    hex(att.authData) === hex(created),
  "attestation object fmt none",
);

// ---- passkey files --------------------------------------------------------------------------
const file = w.encodePasskey({
  id,
  rp: { id: "example.com", name: "Example" },
  user: { id: unhex("75"), name: "u", displayName: "U" },
  signCount: 0,
  privateKey: unhex(
    "01080f161d242b323940474e555c636a71787f868d949ba2a9b0b7bec5ccd3da",
  ),
  created: 1763596800,
});
const raw = w.cborDecode(file);
check(
  Object.keys(raw).join() ===
    "id,rp,user,sign_count,alg,private_key,key_provider,key_format_version,created,discoverable,backup_state,extensions",
  "passkey file: passless's 12 keys in passless's order",
);
check(
  Array.isArray(raw.id) &&
    Array.isArray(raw.user.id) &&
    Array.isArray(raw.private_key),
  "passkey file: byte fields are arrays of uint",
);
const back = w.decodePasskey(file);
check(
  hex(back.id) === hex(id) &&
    back.rp.id === "example.com" &&
    back.user.name === "u" &&
    back.user.displayName === "U" &&
    back.alg === -7 &&
    back.created === 1763596800 &&
    back.discoverable &&
    back.backupEligible,
  "passkey file round trip",
);
const short = w.cborEncode({ ...raw, private_key: unhex("0102") });
check(
  hex(w.decodePasskey(short).privateKey) === "00".repeat(30) + "0102",
  "short private key is left-padded (as the Android app does)",
);

// ---- RP ID checks ---------------------------------------------------------------------------
const rules = w.parseSuffixList(
  fs.readFileSync(path.join(extension, "public_suffix_list.dat"), "utf8"),
);
for (const [host, rpId, ok] of [
  ["example.com", "example.com", true],
  ["login.example.com", "example.com", true],
  ["a.b.example.co.uk", "b.example.co.uk", true],
  ["example.co.uk", "co.uk", false],
  ["alice.github.io", "github.io", false],
  ["alice.github.io", "alice.github.io", true],
  ["example.com", "com", false],
  ["example.com", "evil.com", false],
  ["notexample.com", "example.com", false],
  ["example.com", "login.example.com", false],
  ["a.www.ck", "www.ck", true],
  ["a.b.ck", "b.ck", false],
  ["shop.xn--55qx5d.cn", "xn--55qx5d.cn", false],
  ["localhost", "localhost", true],
  ["a.localhost", "localhost", false],
  ["10.0.0.1", "0.0.1", false],
])
  check(
    w.rpIdAllowed(host, rpId, rules) === ok,
    `rp id ${rpId} on ${host}: ${ok ? "allowed" : "refused"}`,
  );
for (const [url, ok] of [
  ["https://example.com/x", true],
  ["http://localhost:8080/", true],
  ["http://a.localhost/", true],
  ["http://example.com/", false],
  ["file:///x", false],
  ["moz-extension://x/", false],
]) {
  check(
    !!w.secureOrigin(url) === ok,
    `origin ${url}: ${ok ? "secure" : "refused"}`,
  );
}

// ---- host.py with a fake pass ---------------------------------------------------------------
const scratch = fs.mkdtempSync(path.join(os.tmpdir(), "passkey-firefox-unit-"));
const store = path.join(scratch, "store");
const log = path.join(scratch, "pass.log");
fs.mkdirSync(path.join(scratch, "bin"));
fs.writeFileSync(
  path.join(scratch, "bin", "pass"),
  `#!/bin/sh
echo "$* bulk=\${PASS_BULK_KEY_FILE-unset}" >> '${log}'
case "$1" in
  show) cat "$PASSAGE_DIR/$2.age" ;;
  insert) mkdir -p "$(dirname "$PASSAGE_DIR/$4")" && cat > "$PASSAGE_DIR/$4.age" ;;
esac
`,
  { mode: 0o755 },
);
const site = path.join(store, "www", "example.com");
fs.mkdirSync(site, { recursive: true });
for (const f of [
  "user.age",
  "pass.age",
  "otp.age",
  "passkey.age",
  "passkey-0a1b2c3d.age",
  "notes.txt",
])
  fs.writeFileSync(path.join(site, f), f);
fs.writeFileSync(
  path.join(site, "passkey.age"),
  Uint8Array.of(0, 1, 0xff, 10, 13, 0x80),
);

function host(...requests) {
  const input = Buffer.concat(
    requests.map((r) => {
      const body = Buffer.from(typeof r === "string" ? r : JSON.stringify(r));
      const head = Buffer.alloc(4);
      head.writeUInt32LE(body.length);
      return Buffer.concat([head, body]);
    }),
  );
  const out = spawnSync("python3", [hostPy], {
    input,
    env: {
      ...process.env,
      PATH: path.join(scratch, "bin") + ":" + process.env.PATH,
      PASSAGE_DIR: store,
      PASS_BULK_KEY_FILE: "/bulk",
    },
  }).stdout;
  const replies = [];
  for (let at = 0; at < out.length;) {
    const n = out.readUInt32LE(at);
    replies.push(JSON.parse(out.subarray(at + 4, at + 4 + n)));
    at += 4 + n;
  }
  return replies;
}
const calls = () =>
  fs.existsSync(log)
    ? fs.readFileSync(log, "utf8").trim().split("\n").filter(Boolean)
    : [];

let [r] = host({ op: "list", rp: "example.com" });
check(
  JSON.stringify(r.names) === '["passkey","passkey-0a1b2c3d"]',
  `list: only passkey*.age (${JSON.stringify(r.names)})`,
);
[r] = host({ op: "list", rp: "nothing.example" });
check(JSON.stringify(r.names) === "[]", "list of a site without folder: []");
check(calls().length === 0, "list does not run pass");
[r] = host({ op: "read", rp: "example.com", name: "passkey" });
check(
  hex(Buffer.from(r.data, "base64")) === "0001ff0a0d80",
  "read: binary-safe content of pass show",
);
check(
  calls().join("|") === "show www/example.com/passkey bulk=unset",
  `read: one 'pass show', without the bulk key (${calls().join("|")})`,
);
for (const [req, what] of [
  [
    { op: "read", rp: "example.com", name: "user" },
    "read of a non-passkey entry",
  ],
  [
    { op: "read", rp: "example.com", name: "passkey-ffffffff" },
    "read of a missing passkey",
  ],
  [
    { op: "read", rp: "../www/example.com", name: "passkey" },
    "rp id with a path",
  ],
  [{ op: "list", rp: "Example.com" }, "rp id not lowercase"],
  [
    { op: "write", rp: "example.com", id: "../x", data: "" },
    "write with a bad id",
  ],
  [{ op: "delete", rp: "example.com" }, "unknown op"],
  ["{not json", "malformed request"],
]) {
  [r] = host(req);
  check(typeof r.error === "string", `refused: ${what} (${r.error})`);
}
check(calls().length === 1, "refused requests ran no pass");

fs.rmSync(path.join(site, "passkey.age"));
const replies = host(
  {
    op: "write",
    rp: "example.com",
    id: "11223344",
    data: Buffer.from("first\n\0").toString("base64"),
  },
  {
    op: "write",
    rp: "example.com",
    id: "55667788",
    data: Buffer.from("second").toString("base64"),
  },
  {
    op: "write",
    rp: "example.com",
    id: "55667788",
    data: Buffer.from("third").toString("base64"),
  },
  {
    op: "write",
    rp: "new.example",
    id: "99aabbcc",
    data: Buffer.from("fourth").toString("base64"),
  },
);
check(
  replies[0].name === "passkey" &&
    fs.readFileSync(path.join(site, "passkey.age"), "utf8") === "first\n\0",
  "write: first passkey of a site is passkey.age",
);
check(
  replies[1].name === "passkey-55667788" &&
    fs.readFileSync(path.join(site, "passkey-55667788.age"), "utf8") ===
      "second",
  "write: next one is passkey-<8 hex>.age",
);
check(
  /exists/.test(replies[2].error) &&
    fs.readFileSync(path.join(site, "passkey-55667788.age"), "utf8") ===
      "second",
  "write: an existing file is never overwritten",
);
check(replies[3].name === "passkey", "write: new site folder");
check(
  calls().slice(1).join("|") ===
    "insert -m -f www/example.com/passkey bulk=unset|insert -m -f www/example.com/passkey-55667788 bulk=unset|insert -m -f www/new.example/passkey bulk=unset",
  "write: one 'pass insert -m' per stored passkey, several requests per host run",
);
fs.rmSync(scratch, { recursive: true });

console.log(failed ? `${failed} FAILED` : "all unit tests passed");
process.exit(failed ? 1 : 0);
