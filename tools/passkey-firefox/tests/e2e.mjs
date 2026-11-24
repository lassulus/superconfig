// End-to-end: headless Firefox (geckodriver) with the add-on installed as a temporary add-on,
// the native host on a throwaway passage store (plain age identity, HOME in a scratch dir) with
// our real `pass`, behind a shim that logs every call (and takes 3 s per decrypt, longer than the
// background page's idle timeout here). A local RP page, then https://webauthn.io if reachable.
// No npm dependencies: WebDriver over fetch.
//
// Usage: node e2e.mjs <xpi> <passkey-firefox-host package> <pass> <firefox> <geckodriver> <age>
// (python3 on PATH). Environment: KEEP=1 keeps the scratch dir, OFFLINE=1 skips webauthn.io,
// PLAINTEXT_DIR=<dir> receives the decrypted passkey files (for passless's decoder), POLICY=1
// when <firefox> installs the add-on itself (our wrapped firefox) instead of a temporary add-on.

import { execFileSync, spawn } from "node:child_process";
import { createHash, createHmac, createPublicKey, verify } from "node:crypto";
import { createRequire } from "node:module";
import { createServer } from "node:http";
import net from "node:net";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";

const [xpi, hostPkg, pass, firefox, geckodriver, age] = process.argv
  .slice(2)
  .map((p) => p && path.resolve(p));
const w = createRequire(import.meta.url)(
  path.resolve(
    path.dirname(fileURLToPath(import.meta.url)),
    "../extension/webauthn.js",
  ),
);
const extensionId = "passkey-firefox@lassul.us";
const extensionUuid = "6b0c4f4e-6d1a-4c55-9a4e-3f1d2c0b9a77";

const scratch = fs.mkdtempSync(path.join(os.tmpdir(), "passkey-firefox-e2e-"));
const store = path.join(scratch, ".passage", "store");
const passLog = path.join(scratch, "pass.log");
const identity = path.join(scratch, ".passage", "identities");

function check(condition, message) {
  if (!condition) throw new Error("FAILED: " + message);
  console.log("ok   " + message);
}
const b64u = (s) => Buffer.from(s, "base64url");
const passCalls = () =>
  fs.existsSync(passLog)
    ? fs.readFileSync(passLog, "utf8").split("\n").filter(Boolean)
    : [];
const shows = () => passCalls().filter((l) => l.startsWith("show "));
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
// RFC 6238 TOTP (SHA-1, 6 digits, 30 s) of a base32 secret at time t
function totp(secret, t) {
  const bits = Array.from(secret, (c) =>
    "ABCDEFGHIJKLMNOPQRSTUVWXYZ234567".indexOf(c).toString(2).padStart(5, "0"),
  ).join("");
  const counter = Buffer.alloc(8);
  counter.writeBigUInt64BE(BigInt(Math.floor(t / 30)));
  const mac = createHmac(
    "sha1",
    Buffer.from(bits.match(/.{8}/g).map((b) => parseInt(b, 2))),
  )
    .update(counter)
    .digest();
  return String((mac.readUInt32BE(mac[19] & 15) & 0x7fffffff) % 1e6).padStart(
    6,
    "0",
  );
}
const freePort = () =>
  new Promise((resolve) => {
    const s = net.createServer().listen(0, "127.0.0.1", () => {
      const { port } = s.address();
      s.close(() => resolve(port));
    });
  });
function decrypt(file) {
  const plain = execFileSync(age, ["-d", "-i", identity, file]);
  if (process.env.PLAINTEXT_DIR)
    fs.writeFileSync(
      path.join(
        process.env.PLAINTEXT_DIR,
        "e2e_" +
          path.basename(path.dirname(file)) +
          "_" +
          path.basename(file) +
          ".cbor",
      ),
      plain,
    );
  return plain;
}

// ---- passage store (git, like the real one) with a plain age identity ------------------------
fs.mkdirSync(store, { recursive: true });
const keygen = path.join(path.dirname(age), "age-keygen");
execFileSync(keygen, ["-o", identity], { stdio: "ignore" });
fs.writeFileSync(
  path.join(store, ".age-recipients"),
  execFileSync(keygen, ["-y", identity]),
);
const env = {
  ...process.env,
  HOME: scratch,
  XDG_RUNTIME_DIR: path.join(scratch, "run"),
  GIT_AUTHOR_NAME: "e2e",
  GIT_AUTHOR_EMAIL: "e2e@example.com",
  GIT_COMMITTER_NAME: "e2e",
  GIT_COMMITTER_EMAIL: "e2e@example.com",
};
fs.mkdirSync(env.XDG_RUNTIME_DIR, { mode: 0o700 });
execFileSync(pass, ["git", "init"], { env, stdio: "ignore" });

// ---- the installed host, started without any user environment: finds pass by itself ---------
{
  const frame = (o) => {
    const body = Buffer.from(JSON.stringify(o));
    const head = Buffer.alloc(4);
    head.writeUInt32LE(body.length);
    return Buffer.concat([head, body]);
  };
  const outBuf = execFileSync(
    path.join(hostPkg, "bin", "passkey-firefox-host"),
    {
      input: Buffer.concat([
        frame({
          op: "write",
          rp: "clean.example",
          id: "01234567",
          data: "AAEC",
        }),
        frame({ op: "read", rp: "clean.example", name: "passkey" }),
      ]),
      env: {
        HOME: scratch,
        GIT_AUTHOR_NAME: "e2e",
        GIT_AUTHOR_EMAIL: "e",
        GIT_COMMITTER_NAME: "e2e",
        GIT_COMMITTER_EMAIL: "e",
      },
    },
  );
  const first = JSON.parse(outBuf.subarray(4, 4 + outBuf.readUInt32LE(0)));
  const rest = outBuf.subarray(4 + outBuf.readUInt32LE(0));
  const second = JSON.parse(rest.subarray(4, 4 + rest.readUInt32LE(0)));
  check(
    first.name === "passkey" && second.data === "AAEC",
    "installed host with an empty environment: pass insert and pass show work",
  );
  check(
    execFileSync(pass, ["git", "log", "--oneline"], { env })
      .toString()
      .includes("clean.example/passkey"),
    "the write is a git commit of the store",
  );
}

// ---- the host Firefox starts: host.py, `pass` through a logging shim -------------------------
const bin = path.join(scratch, "bin");
fs.mkdirSync(bin);
fs.writeFileSync(
  path.join(bin, "pass"),
  `#!/bin/sh\necho "$*" >> '${passLog}'\n[ "$1" = show ] && sleep 3\nexec '${pass}' "$@"\n`,
  { mode: 0o755 },
);
const hostWrapper = path.join(scratch, "host");
fs.writeFileSync(
  hostWrapper,
  `#!/bin/sh\nPATH='${bin}':$PATH exec python3 '${path.join(hostPkg, "libexec", "host.py")}' 2>> '${path.join(scratch, "host.log")}'\n`,
  { mode: 0o755 },
);
const manifest = path.join(
  scratch,
  ".mozilla",
  "native-messaging-hosts",
  "passkey_firefox.json",
);
fs.mkdirSync(path.dirname(manifest), { recursive: true });
fs.writeFileSync(
  manifest,
  JSON.stringify({
    name: "passkey_firefox",
    description: "e2e",
    path: hostWrapper,
    type: "stdio",
    allowed_extensions: [extensionId],
  }),
);

// ---- the relying party: a local page, plus a frame from another origin -----------------------
const rpScript = `
const b64u = (buf) => btoa(String.fromCharCode(...new Uint8Array(buf))).replace(/\\+/g, "-").replace(/\\//g, "_").replace(/=+$/, "");
const fromB64u = (s) => Uint8Array.from(atob(s.replace(/-/g, "+").replace(/_/g, "/")), (c) => c.charCodeAt(0));
const rnd = () => crypto.getRandomValues(new Uint8Array(32));
window.register = async (name, exclude = []) => {
  const challenge = rnd();
  const c = await navigator.credentials.create({ publicKey: {
    rp: { name: "e2e" }, user: { id: new TextEncoder().encode(name), name, displayName: name.toUpperCase() },
    challenge, pubKeyCredParams: [{ type: "public-key", alg: -7 }],
    excludeCredentials: exclude.map((id) => ({ type: "public-key", id: fromB64u(id) })),
    authenticatorSelection: { residentKey: "required", userVerification: "preferred" },
    timeout: 60000, extensions: { credProps: true } } });
  return { json: c.toJSON(), challenge: b64u(challenge), pkc: c instanceof PublicKeyCredential,
           attestation: c.response instanceof AuthenticatorAttestationResponse,
           rawIdMatches: b64u(c.rawId) === c.id, alg: c.response.getPublicKeyAlgorithm(),
           rk: c.getClientExtensionResults().credProps?.rk };
};
window.signIn = async (ids, signal) => {
  const challenge = rnd();
  const a = await navigator.credentials.get({ signal, publicKey: { challenge, timeout: 60000,
    allowCredentials: ids.map((id) => ({ type: "public-key", id: fromB64u(id) })),
    userVerification: "preferred" } });
  return { json: a.toJSON(), challenge: b64u(challenge), pkc: a instanceof PublicKeyCredential,
           assertion: a.response instanceof AuthenticatorAssertionResponse,
           userHandle: new TextDecoder().decode(a.response.userHandle) };
};
window.outcome = (p) => p.then(() => "resolved", (e) => e.name);
window.later = (p) => { window.pending = p.then((v) => ({ value: v }), (e) => ({ error: e.name + ": " + e.message })); return 1; };
`;
// webauthn.io's own API, with the page's SimpleWebAuthn
const wioScript = `
const post = (url, body) => fetch(url, { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify(body) }).then((r) => r.json());
window.wioRegister = async (username) => {
  const options = await post("/registration/options", { username, user_verification: "preferred", attestation: "none",
    attachment: "all", algorithms: ["es256"], discoverable_credential: "required", hints: [] });
  const response = await SimpleWebAuthnBrowser.startRegistration({ optionsJSON: options });
  return { response, verification: await post("/registration/verification", { username, response }) };
};
window.wioSignIn = async (username) => {
  const options = await post("/authentication/options", { username, user_verification: "preferred", hints: [] });
  const response = await SimpleWebAuthnBrowser.startAuthentication({ optionsJSON: options });
  return { options, response, verification: await post("/authentication/verification", { username, response }) };
};
window.later = (p) => { window.pending = p.then((v) => ({ value: v }), (e) => ({ error: e.name + ": " + e.message })); return 1; };
`;
// login forms: with an OTP field (/login) and without (/plain); they log input/change events
const loginPage = (otp) => `<!doctype html><title>login</title><form>
<input id="user" type="email" autocomplete="username"><input id="pass" type="password">
${otp ? '<input id="otp" autocomplete="one-time-code" inputmode="numeric">' : ""}</form><script>
window.events = []; for (const el of document.querySelectorAll("input")) for (const t of ["input", "change"]) el.addEventListener(t, () => events.push(el.id + ":" + t));
</script>`;
const server = createServer((req, res) => {
  res.setHeader("content-type", "text/html");
  if (req.url.startsWith("/login")) res.end(loginPage(true));
  else if (req.url.startsWith("/plain")) res.end(loginPage(false));
  else res.end(`<!doctype html><title>rp</title><script>${rpScript}</script>`);
}).listen(0, "127.0.0.1");
await new Promise((r) => server.once("listening", r));
const port = server.address().port;
const origin = `http://localhost:${port}`;

// ---- Firefox through geckodriver -------------------------------------------------------------
const driverPort = await freePort();
const driver = spawn(
  geckodriver,
  // system access: the chrome context, to open popup.html in a tab
  ["--port", String(driverPort), "--binary", firefox, "--allow-system-access"],
  {
    env: { ...env, PATH: process.env.PATH },
    stdio: ["ignore", "pipe", "pipe"],
  },
);
let driverLog = "";
driver.stdout.on("data", (d) => (driverLog += d));
driver.stderr.on("data", (d) => (driverLog += d));
const base = `http://127.0.0.1:${driverPort}`;
async function wd(method, url, body) {
  const res = await fetch(base + url, {
    method,
    headers: { "content-type": "application/json" },
    body: body === undefined ? undefined : JSON.stringify(body),
  });
  const json = await res.json();
  if (!res.ok)
    throw new Error(`${method} ${url}: ${JSON.stringify(json.value)}`);
  return json.value;
}
for (let i = 0; i < 100; i++) {
  try {
    await fetch(base + "/status");
    break;
  } catch {
    await sleep(100);
  }
}

let session;
let exitCode = 0;
try {
  session = await wd("POST", "/session", {
    capabilities: {
      alwaysMatch: {
        browserName: "firefox",
        unhandledPromptBehavior: "ignore",
        "moz:firefoxOptions": {
          args: ["-headless"],
          // the background page sleeps after 2 s idle: decrypts (3 s here) must keep it alive
          prefs: {
            "browser.shell.checkDefaultBrowser": false,
            "extensions.background.idle.timeout": 2000,
            // a fixed moz-extension:// host, to load popup.html
            "extensions.webextensions.uuids": JSON.stringify({
              [extensionId]: extensionUuid,
            }),
            // the virtual authenticator of the fallback checks
            "security.webauth.webauthn_enable_softtoken": true,
            "security.webauth.webauthn_enable_usbtoken": false,
          },
        },
      },
    },
  });
  const sid = session.sessionId;
  check(
    session.capabilities.browserName === "firefox",
    `Firefox ${session.capabilities.browserVersion} started headless`,
  );
  if (process.env.POLICY) {
    // our wrapped firefox: the add-on comes from its policies.json; its other
    // add-ons (workspace tabs) may close the first tab: use the one left
    await sleep(2000);
    const [handle] = await wd("GET", `/session/${sid}/window/handles`);
    await wd("POST", `/session/${sid}/window`, { handle });
    console.log(
      "ok   (the add-on comes from the policy; the checks below need it)",
    );
  } else {
    const id = await wd("POST", `/session/${sid}/moz/addon/install`, {
      addon: fs.readFileSync(xpi).toString("base64"),
      temporary: true,
    });
    check(id === extensionId, `the add-on is installed from the .xpi (${id})`);
  }
  // The browser's own WebAuthn gets a virtual authenticator: the fallback is observable.
  const virtual = await wd("POST", `/session/${sid}/webauthn/authenticator`, {
    protocol: "ctap2",
    transport: "usb",
    hasResidentKey: true,
    hasUserVerification: true,
    isUserConsenting: true,
    isUserVerified: true,
  });

  const run = (expression) =>
    wd("POST", `/session/${sid}/execute/async`, {
      script: `const done = arguments[arguments.length - 1];
               Promise.resolve().then(() => ${expression}).then(done, (e) => done({ error: e.name + ": " + e.message }));`,
      args: [],
    }).then((value) => {
      if (value && value.error)
        throw new Error(expression + ": " + value.error);
      return value;
    });
  const start = (expression) =>
    wd("POST", `/session/${sid}/execute/sync`, {
      script: `return later(${expression})`,
      args: [],
    });
  const finish = () =>
    run("window.pending").then((r) => {
      if (r.error) throw new Error(r.error);
      return r.value;
    });
  // answers the add-on's confirm() in the page
  async function answer(accept) {
    for (let i = 0; i < 300; i++) {
      try {
        const text = await wd("GET", `/session/${sid}/alert/text`);
        await wd(
          "POST",
          `/session/${sid}/alert/${accept ? "accept" : "dismiss"}`,
          {},
        );
        return text;
      } catch {
        await sleep(100);
      }
    }
    throw new Error("no confirm() appeared");
  }
  const site = path.join(store, "www", "localhost");

  await wd("POST", `/session/${sid}/url`, { url: origin });
  check(
    (await run(
      "PublicKeyCredential.isUserVerifyingPlatformAuthenticatorAvailable()",
    )) === true,
    "isUserVerifyingPlatformAuthenticatorAvailable() is true",
  );

  // ---- registration --------------------------------------------------------------------------
  await start('register("alice")');
  const question = await answer(true);
  check(
    /Create a passkey for localhost as "alice"/.test(question),
    `registration asks first: "${question.split("\n")[0]}"`,
  );
  const reg = await finish();
  check(
    reg.pkc &&
      reg.attestation &&
      reg.rawIdMatches &&
      reg.alg === -7 &&
      reg.rk === true,
    "create() gives a PublicKeyCredential, alg -7, credProps.rk",
  );
  const cdj = JSON.parse(b64u(reg.json.response.clientDataJSON));
  check(
    cdj.type === "webauthn.create" &&
      cdj.origin === origin &&
      cdj.challenge === reg.challenge &&
      cdj.crossOrigin === false,
    "registration clientDataJSON: type, origin, challenge",
  );
  const att = w.cborDecode(b64u(reg.json.response.attestationObject));
  const authData = att.authData;
  check(
    att.fmt === "none" &&
      authData
        .subarray(0, 32)
        .equals(createHash("sha256").update("localhost").digest()) &&
      authData[32] === 0x5d,
    "attestation: fmt none, rpIdHash of localhost, flags UP|UV|BE|BS|AT",
  );
  check(
    b64u(reg.json.rawId).equals(authData.subarray(55, 87)) &&
      authData.readUInt32BE(33) === 0,
    "attestation: credential id = rawId, counter 0",
  );
  const publicKey = createPublicKey({
    key: b64u(reg.json.response.publicKey),
    format: "der",
    type: "spki",
  });
  const cose = w.cborDecode(authData.subarray(87));
  const pubJwk = publicKey.export({ format: "jwk" });
  check(
    Buffer.from(cose[-2]).toString("base64url") === pubJwk.x &&
      Buffer.from(cose[-3]).toString("base64url") === pubJwk.y,
    "attestation: COSE key = getPublicKey()",
  );
  check(
    fs.existsSync(path.join(site, "passkey.age")),
    "stored as www/localhost/passkey.age",
  );
  check(
    shows().length === 0 &&
      passCalls().join("|") === "insert -m -f www/localhost/passkey",
    `registration: one pass insert, no decrypt (${passCalls().join("|")})`,
  );
  const alice = w.decodePasskey(decrypt(path.join(site, "passkey.age")));
  check(
    alice.id.length === 32 &&
      b64u(reg.json.rawId).equals(Buffer.from(alice.id)) &&
      alice.user.name === "alice" &&
      alice.user.displayName === "ALICE" &&
      alice.signCount === 0,
    "the stored passkey decrypts with the passage identity: id, user, sign_count 0",
  );
  const aliceFile = fs.readFileSync(path.join(site, "passkey.age"));

  // ---- sign-ins: one pass show each, valid signature ----------------------------------------
  for (let n = 1; n <= 2; n++) {
    const got = await run(`signIn([${JSON.stringify(reg.json.id)}])`);
    check(
      got.pkc &&
        got.assertion &&
        got.json.id === reg.json.id &&
        got.userHandle === "alice",
      `sign-in ${n}: the registered credential, userHandle alice`,
    );
    const gcdj = JSON.parse(b64u(got.json.response.clientDataJSON));
    check(
      gcdj.type === "webauthn.get" &&
        gcdj.origin === origin &&
        gcdj.challenge === got.challenge,
      `sign-in ${n}: clientDataJSON`,
    );
    const ad = b64u(got.json.response.authenticatorData);
    check(
      ad.length === 37 && ad[32] === 0x1d && ad.readUInt32BE(33) === 0,
      `sign-in ${n}: flags UP|UV|BE|BS, counter 0`,
    );
    const signed = Buffer.concat([
      ad,
      createHash("sha256")
        .update(b64u(got.json.response.clientDataJSON))
        .digest(),
    ]);
    check(
      verify("sha256", signed, publicKey, b64u(got.json.response.signature)),
      `sign-in ${n}: DER signature verifies with the registered key`,
    );
    check(
      shows().length === n && shows()[n - 1] === "show www/localhost/passkey",
      `sign-in ${n}: ${shows().length} pass show(s) so far, of www/localhost/passkey`,
    );
  }
  check(
    fs.readFileSync(path.join(site, "passkey.age")).equals(aliceFile),
    "sign-ins do not rewrite the passkey (zero signature counter)",
  );

  // ---- a second account ------------------------------------------------------------------
  await start('register("bob")');
  await answer(true);
  const bob = await finish();
  const bobFile = `passkey-${b64u(bob.json.rawId).subarray(0, 4).toString("hex")}`;
  check(
    fs.existsSync(path.join(site, bobFile + ".age")) &&
      fs.readFileSync(path.join(site, "passkey.age")).equals(aliceFile),
    `second account stored as ${bobFile}.age, passkey.age untouched`,
  );
  w.decodePasskey(decrypt(path.join(site, bobFile + ".age")));
  let before = shows().length;
  const gotBob = await run(`signIn([${JSON.stringify(bob.json.id)}])`);
  check(
    gotBob.json.id === bob.json.id && gotBob.userHandle === "bob",
    "sign-in with allowCredentials [bob] returns bob",
  );
  check(
    shows().slice(before).join("|") === `show www/localhost/${bobFile}`,
    `... decrypting only ${bobFile} (${shows().slice(before).join("|")})`,
  );

  // ---- no allowCredentials, two accounts: the user picks, account by account ---------------
  before = shows().length;
  await start("signIn([])");
  const first = await answer(false);
  const second = await answer(true);
  const picked = await finish();
  check(
    /Sign in to localhost as "alice"/.test(first) &&
      /as "bob"/.test(second) &&
      picked.json.id === bob.json.id,
    `discoverable: asked for alice (no), bob (yes): bob signs in`,
  );
  check(
    shows().length - before === 2,
    "discoverable: one decrypt per account offered",
  );

  // ---- refusals ------------------------------------------------------------------------------
  before = passCalls().length;
  const excluded = await run(
    `outcome(register("bob", [${JSON.stringify(bob.json.id)}]))`,
  );
  check(
    excluded === "InvalidStateError" && passCalls().length === before,
    `excludeCredentials [bob]: ${excluded}, nothing stored`,
  );
  const foreign = await run(
    'outcome(navigator.credentials.get({ publicKey: { rpId: "example.com", challenge: new Uint8Array(32) } }))',
  );
  check(foreign === "SecurityError", `foreign rpId: ${foreign}`);
  const suffix = await run(
    'outcome(navigator.credentials.create({ publicKey: { rp: { id: "com", name: "x" }, user: { id: new Uint8Array(1), name: "x", displayName: "x" }, challenge: new Uint8Array(32), pubKeyCredParams: [{ type: "public-key", alg: -7 }] } }))',
  );
  check(suffix === "SecurityError", `rpId a public suffix: ${suffix}`);
  check(passCalls().length === before, "refused requests ran no pass");
  const abortedEarly = await run(
    "(() => { const c = new AbortController(); const p = signIn([], c.signal); c.abort(); return outcome(p); })()",
  );
  check(abortedEarly === "AbortError", `abort right away: ${abortedEarly}`);
  const t0 = Date.now();
  const abortedLate = await run(
    `(() => { const c = new AbortController(); const p = signIn([${JSON.stringify(reg.json.id)}], c.signal); setTimeout(() => c.abort(), 1000); return outcome(p); })()`,
  );
  check(
    abortedLate === "AbortError" && Date.now() - t0 < 2900,
    `abort during the decrypt: ${abortedLate} after ${Date.now() - t0} ms`,
  );
  await sleep(3000);

  await run(
    `new Promise((resolve) => { const f = document.createElement("iframe"); f.src = "http://other.localhost:${port}"; f.onload = resolve; document.body.append(f); })`,
  );
  const frame = await wd("POST", `/session/${sid}/execute/sync`, {
    script: "return document.querySelector('iframe')",
    args: [],
  });
  before = passCalls().length;
  await wd("POST", `/session/${sid}/frame`, { id: frame });
  const framed = await run(`outcome(signIn([]))`);
  await wd("POST", `/session/${sid}/frame/parent`, {});
  check(
    framed === "NotAllowedError" && passCalls().length === before,
    `cross-origin frame refused without running pass (${framed})`,
  );

  // ---- fallbacks to the browser's own WebAuthn ------------------------------------------------
  before = passCalls().length;
  await start('register("carol")');
  await answer(false);
  const carol = await finish();
  const credentials = await wd(
    "GET",
    `/session/${sid}/webauthn/authenticator/${virtual}/credentials`,
  );
  check(
    credentials.some((c) => c.credentialId === carol.json.id) &&
      passCalls().length === before,
    "registration cancelled: the browser's authenticator registers instead, nothing stored",
  );
  fs.renameSync(manifest, manifest + ".off");
  const native = await run("signIn([])");
  check(
    native.json.id === carol.json.id && passCalls().length === before,
    "host not installed: the browser's authenticator signs in",
  );
  fs.renameSync(manifest + ".off", manifest);
  check(
    (await run(`signIn([${JSON.stringify(carol.json.id)}])`)).json.id ===
      carol.json.id && shows().slice(-1)[0] === "show www/localhost/passkey",
    "a credential not in the store (after reading passkey.age, its name says nothing): the browser answers",
  );

  // ---- logins ------------------------------------------------------------------------------
  // WebDriver cannot click the toolbar button or a context menu item, nor navigate to an
  // extension page. The test opens popup.html in a second tab from the browser chrome and sends
  // the requests its buttons send; a context menu click is the same fill request with the
  // clicked frame's id (the popup gets it from the background).
  for (const [name, content] of [
    ["user", "alice@example.com"],
    ["pass", "alice-secret\nnotes: second line"],
    ["otp", "otpauth://totp/e2e?secret=JBSWY3DPEHPK3PXP&issuer=e2e"],
    ["bob/pass", "bob-secret"],
  ])
    execFileSync(pass, ["insert", "-m", "-f", `www/localhost/${name}`], {
      env,
      input: content + "\n",
    });
  before = passCalls().length;
  const pageTab = await wd("GET", `/session/${sid}/window`);
  await wd("POST", `/session/${sid}/url`, { url: `${origin}/login` });
  await wd("POST", `/session/${sid}/moz/context`, { context: "chrome" });
  await wd("POST", `/session/${sid}/execute/sync`, {
    script: `gBrowser.addTab(arguments[0], { triggeringPrincipal: Services.scriptSecurityManager.getSystemPrincipal() }); return 1;`,
    args: [`moz-extension://${extensionUuid}/popup.html`],
  });
  await wd("POST", `/session/${sid}/moz/context`, { context: "content" });
  await sleep(1000);
  const popupTab = (await wd("GET", `/session/${sid}/window/handles`)).find(
    (h) => h !== pageTab,
  );
  const inTab = async (handle, f) => {
    await wd("POST", `/session/${sid}/window`, { handle });
    return f();
  };
  await inTab(popupTab, async () => {});
  const ext = (code) =>
    run(
      `(async (browser) => ({ value: await (async () => { ${code} })() }))(window.browser || window.wrappedJSObject.browser)`,
    ).then((r) => r.value);
  const tabId = await ext(
    `return (await browser.tabs.query({})).find((t) => t.url.startsWith(${JSON.stringify(origin)})).id;`,
  );
  const ask = (msg) =>
    ext(
      `return browser.runtime.sendMessage({ tabId: ${tabId}, ...${JSON.stringify(msg)} });`,
    );
  const listed = await ask({ type: "logins" });
  const entries = listed.logins.map((e) => [e.site, e.account, e.user, e.otp]);
  check(
    listed.frameId === 0 &&
      JSON.stringify(entries) ===
        '[["localhost","",true,true],["localhost","bob",false,false]]',
    `logins of the tab: localhost (user, pass, otp) and bob (subfolder, pass only)`,
  );
  check(
    passCalls().length === before,
    "loading the login page and listing ran no pass",
  );

  const aliceLogin = { site: "localhost", account: "" };
  const filled = await ask({ type: "fill", ...aliceLogin, frameId: 0 });
  check(
    filled.filled?.join() === "user,pass,otp",
    `fill: ${JSON.stringify(filled)}`,
  );
  check(
    passCalls().slice(before).join("|") ===
      "show www/localhost/user|show www/localhost/pass|otp www/localhost/otp",
    "fill: one pass show each for user.age and pass.age, pass otp for otp.age",
  );
  const form = () =>
    inTab(pageTab, () =>
      run(
        "({ user: user.value, pass: pass.value, otp: window.otp?.value, events })",
      ),
    );
  let got = await form();
  const now = Date.now() / 1000;
  check(
    got.user === "alice@example.com" && got.pass === "alice-secret",
    "fill: user and first line of pass.age in the fields",
  );
  check(
    [
      totp("JBSWY3DPEHPK3PXP", now),
      totp("JBSWY3DPEHPK3PXP", now - 30),
    ].includes(got.otp),
    `fill: the TOTP code of the otpauth URI (${got.otp})`,
  );
  check(
    got.events.join() ===
      "user:input,user:change,pass:input,pass:change,otp:input,otp:change",
    "fill: input and change events",
  );

  before = passCalls().length;
  await inTab(popupTab, async () => {});
  check(
    (
      await ask({ type: "fill", site: "localhost", account: "bob", frameId: 0 })
    ).filled?.join() === "user,pass",
    "fill bob: user and pass (no otp.age)",
  );
  got = await form();
  check(
    got.user === "bob" && got.pass === "bob-secret",
    "fill bob: the folder name as user name",
  );
  check(
    passCalls().slice(before).join("|") === "show www/localhost/bob/pass",
    "fill bob: one pass show",
  );

  // frames: same origin is filled, another origin refused before any decrypt
  await inTab(pageTab, () =>
    wd("POST", `/session/${sid}/url`, { url: origin }),
  );
  await run(
    `Promise.all(["${origin}/plain", "http://other.localhost:${port}/plain"].map((src) => new Promise((resolve) => { const f = document.createElement("iframe"); f.src = src; f.onload = resolve; document.body.append(f); })))`,
  );
  await inTab(popupTab, async () => {});
  const frames = await ext(
    `return (await browser.scripting.executeScript({ target: { tabId: ${tabId}, allFrames: true }, func: () => location.href })).map((r) => [r.frameId, r.result]);`,
  );
  const frameOf = (url) => frames.find(([, href]) => href === url)[0];
  before = passCalls().length;
  const top = await ask({ type: "fill", ...aliceLogin, frameId: 0 });
  check(
    /no login fields/.test(top.error) && passCalls().length === before,
    `top frame without fields: ${top.error}, no decrypt`,
  );
  const cross = await ask({
    type: "fill",
    ...aliceLogin,
    frameId: frameOf(`http://other.localhost:${port}/plain`),
  });
  check(
    /refused/.test(cross.error) && passCalls().length === before,
    `cross-origin frame: ${cross.error}, no decrypt`,
  );
  const same = await ask({
    type: "fill",
    ...aliceLogin,
    frameId: frameOf(`${origin}/plain`),
  });
  check(
    same.filled?.join() === "user,pass",
    "same-origin frame (as clicked in its context menu): user, pass",
  );
  check(
    passCalls().slice(before).join("|") ===
      "show www/localhost/user|show www/localhost/pass",
    "same-origin frame: no otp (no field), two pass show",
  );
  got = await inTab(pageTab, async () => {
    const frame = await wd("POST", `/session/${sid}/execute/sync`, {
      script: "return document.querySelector('iframe')",
      args: [],
    });
    await wd("POST", `/session/${sid}/frame`, { id: frame });
    const values = await run("({ user: user.value, pass: pass.value })");
    await wd("POST", `/session/${sid}/frame/parent`, {});
    return values;
  });
  check(
    got.user === "alice@example.com" && got.pass === "alice-secret",
    "same-origin frame: values in its fields",
  );

  // copy: in the clipboard, cleared after 45 s
  before = passCalls().length;
  await inTab(popupTab, async () => {});
  check(
    (
      await ask({
        type: "copy",
        site: "localhost",
        account: "bob",
        field: "pass",
      })
    ).copied === "pass",
    "copy bob's pass",
  );
  check(
    (await ext("return navigator.clipboard.readText();")) === "bob-secret",
    "the clipboard holds it",
  );
  check(
    passCalls().slice(before).join("|") === "show www/localhost/bob/pass",
    "copy: one pass show",
  );
  await sleep(50000);
  check(
    (await ext("return navigator.clipboard.readText();")) === "",
    "the clipboard is cleared after 45 s",
  );
  await ask({ type: "copy", site: "localhost", account: "bob", field: "user" });
  await ext(
    'return navigator.clipboard.writeText("copied by the user meanwhile");',
  );
  await sleep(50000);
  check(
    (await ext("return navigator.clipboard.readText();")) ===
      "copied by the user meanwhile",
    "a clipboard that changed meanwhile is left alone",
  );
  await inTab(pageTab, async () => {});

  // ---- webauthn.io ---------------------------------------------------------------------------
  if (process.env.OFFLINE) {
    console.log("skip webauthn.io (OFFLINE)");
  } else {
    await wd("POST", `/session/${sid}/url`, { url: "https://webauthn.io/" });
    await wd("POST", `/session/${sid}/execute/sync`, {
      script: `const s = document.createElement("script"); s.textContent = arguments[0]; document.head.append(s); return 1;`,
      args: [wioScript],
    });
    const wio = path.join(store, "www", "webauthn.io");
    const users = [
      "pkff-" + Date.now().toString(36),
      "pkff2-" + Date.now().toString(36),
    ];
    for (const [i, user] of users.entries()) {
      await start(`wioRegister(${JSON.stringify(user)})`);
      check(
        /Create a passkey for webauthn.io/.test(await answer(true)),
        `webauthn.io: registration of ${user} asks`,
      );
      const r = await finish();
      check(
        r.verification.verified === true,
        `webauthn.io: registration of ${user} verified by the server`,
      );
      const name =
        i === 0
          ? "passkey"
          : `passkey-${b64u(r.response.rawId).subarray(0, 4).toString("hex")}`;
      check(
        fs.existsSync(path.join(wio, name + ".age")),
        `webauthn.io: stored as www/webauthn.io/${name}.age`,
      );
      w.decodePasskey(decrypt(path.join(wio, name + ".age")));
      for (let n = 1; n <= 2; n++) {
        before = shows().length;
        const s = await run(`wioSignIn(${JSON.stringify(user)})`);
        check(
          s.verification.verified === true && s.response.id === r.response.id,
          `webauthn.io: sign-in ${n} of ${user} verified by the server`,
        );
        check(
          shows().slice(before).join("|") === `show www/webauthn.io/${name}`,
          `webauthn.io: ... with one pass show of ${name}`,
        );
      }
    }
  }
} catch (e) {
  console.error(e.message);
  exitCode = 1;
} finally {
  if (session)
    await wd("DELETE", `/session/${session.sessionId}`).catch(() => {});
  driver.kill();
  server.close();
  const hostLog = path.join(scratch, "host.log");
  if (fs.existsSync(hostLog) && fs.statSync(hostLog).size)
    console.log(
      "--- host stderr (tail) ---\n" +
        fs.readFileSync(hostLog, "utf8").split("\n").slice(-15).join("\n"),
    );
  if (exitCode)
    console.log(
      "--- geckodriver (tail) ---\n" +
        driverLog.split("\n").slice(-40).join("\n"),
    );
  console.log(
    `pass calls: ${passCalls().length}, of them pass show: ${shows().length}`,
  );
  if (!process.env.KEEP) fs.rmSync(scratch, { recursive: true, force: true });
  else console.log("scratch kept: " + scratch);
  console.log(exitCode ? "E2E FAILED" : "E2E PASSED");
  process.exit(exitCode);
}
