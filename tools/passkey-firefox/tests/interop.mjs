// Format interop: decodes the passkey files of passage stores written by passless and by the
// Android app (fixture dirs with `identities` and `store/www/<rp>/passkey*.age`), checks them
// against the fixture READMEs, and writes every plaintext plus one file encoded by webauthn.js
// to <out dir> as *.cbor for other decoders (passless's Credential::from_bytes).
// Usage: node interop.mjs <extension dir> <age> <out dir> <fixture dir>...

import { execFileSync } from "node:child_process";
import { createRequire } from "node:module";
import fs from "node:fs";
import path from "node:path";

const [extension, age, out, ...fixtures] = process.argv
  .slice(2)
  .map((p) => path.resolve(p));
const w = createRequire(import.meta.url)(path.join(extension, "webauthn.js"));
const hex = (b) => Buffer.from(b).toString("hex");
let failed = 0;
function check(ok, what) {
  console.log((ok ? "ok   " : "FAIL ") + what);
  if (!ok) failed++;
}

// From the fixture READMEs: id -> [user handle, name, display name, sign_count, private key, created, backup eligible]
const expected = {
  a1b2c3d4e5f60718293a4b5c6d7e8f90: [
    "alice-user-handle",
    "alice",
    "Alice Example",
    3,
    "01080f161d242b323940474e555c636a71787f868d949ba2a9b0b7bec5ccd3da",
    1763596800,
    false,
  ],
  "5e7c0ffee0ddba11cafe0123456789ab": [
    "bob-user-handle",
    "bob",
    "Bob Example",
    3,
    "020910171e252c333a41484f565d646b727980878e959ca3aab1b8bfc6cdd4db",
    1763596800,
    false,
  ],
  f0e9e2dbd4cdc6bfb8b1aaa39c958e87: [
    "bob-user-handle",
    "bob",
    "Bob Example",
    5,
    "202326292c2f3235383b3e4144474a4d505356595c5f6265686b6e7174777a7d",
    1763683200,
    true,
  ],
  a099928b847d766f68615a534c453e37: [
    "carol-user-handle",
    "carol",
    "Carol Example",
    6,
    "606366696c6f7275787b7e8184878a8d909396999c9fa2a5a8abaeb1b4b7babd",
    1763769600,
    true,
  ],
};

fs.mkdirSync(out, { recursive: true });
const seen = new Set();
for (const fixture of fixtures) {
  const www = path.join(fixture, "store", "www");
  for (const rp of fs.readdirSync(www)) {
    for (const file of fs
      .readdirSync(path.join(www, rp))
      .filter((f) => /^passkey(-.+)?\.age$/.test(f))) {
      const label = `${path.basename(fixture)}/${rp}/${file}`;
      const plain = execFileSync(age, [
        "-d",
        "-i",
        path.join(fixture, "identities"),
        path.join(www, rp, file),
      ]);
      fs.writeFileSync(
        path.join(out, label.replace(/\//g, "_") + ".cbor"),
        plain,
      );
      const c = w.decodePasskey(plain);
      const idHex = hex(c.id);
      const e = expected[idHex];
      seen.add(idHex);
      check(!!e, `${label}: decodes, id ${idHex}`);
      if (!e) continue;
      check(
        file === "passkey.age" || file === `passkey-${idHex.slice(0, 8)}.age`,
        `${label}: file name fits the id`,
      );
      check(
        c.rp.id === rp && c.alg === -7 && c.discoverable,
        `${label}: rp ${c.rp.id}, alg -7, discoverable`,
      );
      check(
        Buffer.from(c.user.id).toString() === e[0] &&
          c.user.name === e[1] &&
          c.user.displayName === e[2],
        `${label}: user ${c.user.name}`,
      );
      check(
        c.signCount === e[3] &&
          hex(c.privateKey) === e[4] &&
          c.created === e[5] &&
          c.backupEligible === e[6],
        `${label}: sign_count ${c.signCount}, private key, created, backup state`,
      );
      const raw = w.cborDecode(plain);
      if (raw.public_key) {
        const jwk = w.privateJwk(c.privateKey);
        check(
          hex(raw.public_key) ===
            "04" + hex(w.fromB64u(jwk.x)) + hex(w.fromB64u(jwk.y)),
          `${label}: Android's public_key = the point derived from the scalar`,
        );
      }
    }
  }
}
check(
  Object.keys(expected).every((id) => seen.has(id)),
  "all README passkeys found",
);

const mine = w.encodePasskey({
  id: Uint8Array.from(Buffer.from("c0ffee00" + "11".repeat(28), "hex")),
  rp: { id: "webauthn.io", name: null },
  user: {
    id: Buffer.from("dave-user-handle"),
    name: "dave",
    displayName: "Dave Example",
  },
  signCount: 0,
  privateKey: Uint8Array.from(
    Buffer.from(expected.a1b2c3d4e5f60718293a4b5c6d7e8f90[4], "hex"),
  ),
  created: 1764000000,
});
fs.writeFileSync(path.join(out, "zz_passkey-firefox.cbor"), mine);
const keys = Object.keys(w.cborDecode(mine));
// passless: every field of Credential (credential.rs); Android (StoredCredential.fromCbor): id, rp,
// user, sign_count, alg, private_key, created required; discoverable, extensions, backup_state
// optional; public_key optional.
check(
  keys.join() ===
    "id,rp,user,sign_count,alg,private_key,key_provider,key_format_version,created,discoverable,backup_state,extensions",
  "passkey-firefox file: passless's field set and order",
);
const fixtureKeys = Object.keys(
  w.cborDecode(
    fs.readFileSync(
      path.join(
        out,
        fs.readdirSync(out).find((f) => f.startsWith("interop-fixture")),
      ),
    ),
  ),
);
check(
  keys.join() === fixtureKeys.join(),
  "passkey-firefox file: same keys as the passless fixture",
);

console.log(failed ? `${failed} FAILED` : "interop passed");
process.exit(failed ? 1 : 0);
