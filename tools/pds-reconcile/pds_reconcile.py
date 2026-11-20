# Creates the accounts of a Tranquil PDS that sign in via a Zitadel OIDC
# provider, and their Tangled SSH keys, from a declarative list.
#
# For each account (by email address):
# - Its Zitadel user (the OIDC `sub`) is looked up; trusted are users who
#   verified the address, or who were created by an admin and have no login
#   yet (invite pending), as in zitadel-reconcile.
# - An account linked to that `sub` is left alone. Otherwise, for accounts
#   with a handle, one is created the way Tranquil's own SSO signup does it:
#   a pending SSO registration (what the OIDC callback stores, with the
#   address marked verified by the IdP) is completed through
#   /oauth/sso/complete-registration. Tranquil creates the DID, the repo and
#   the link to the `sub`, and takes the address as verified, so "Sign in
#   with <IdP>" logs into the account. Accounts without a handle are only
#   looked up, their owners sign up themselves.
# - Missing org.tangled.key.sshKey records for the declared keys are created;
#   records it created earlier whose key is no longer declared are deleted.
#   Keys a user added themselves are never deleted. Writes go through a
#   session of a temporary app password, scoped to that collection and
#   deleted afterwards.
#
# Tranquil has no admin credential for this, so the database (as Tranquil's
# user, via psql) is the authorization: it holds just the pending
# registration and the temporary app password.
import json
import os
import secrets
import subprocess
import sys
import time
import urllib.error
import urllib.parse
import urllib.request

import bcrypt

[config_path] = sys.argv[1:]
with open(config_path) as f:
    config = json.load(f)

COLLECTION = "org.tangled.key.sshKey"
PROFILE = "org.tangled.actor.profile"
APP_PASSWORD = "pds-reconcile"
PROVIDER = "oidc"


class Failed(Exception):
    pass


def request(base, method, path, body=None, headers={}):
    req = urllib.request.Request(
        base + path,
        method=method,
        headers={"Content-Type": "application/json", **headers},
        data=None if body is None else json.dumps(body).encode(),
    )
    try:
        with urllib.request.urlopen(req) as res:
            data = res.read()
    except urllib.error.HTTPError as e:
        raise Failed(f"{method} {path}: {e.code} {e.read().decode()}")
    return json.loads(data) if data else None


def wait_for(base, path, headers={}):
    while True:
        try:
            request(base, "GET", path, headers=headers)
            return
        except (Failed, urllib.error.URLError, ConnectionError):
            time.sleep(1)


zitadel = config["zitadel"]
zitadel_headers = {"Host": zitadel["domain"]}
with open(zitadel["tokenFile"]) as f:
    zitadel_headers["Authorization"] = "Bearer " + f.read().strip()


def zitadel_user(email):
    users = request(
        zitadel["url"],
        "POST",
        "/management/v1/users/_search",
        {"queries": [
            {"emailQuery": {
                "emailAddress": email,
                "method": "TEXT_QUERY_METHOD_EQUALS_IGNORE_CASE",
            }},
            {"typeQuery": {"type": "TYPE_HUMAN"}},
        ]},
        zitadel_headers,
    ).get("result", [])
    trusted = [
        u for u in users
        if u["human"].get("email", {}).get("isEmailVerified")
        or u.get("state") == "USER_STATE_INITIAL"
    ]
    if len(trusted) != 1:
        # not registered or verified yet, as in zitadel-reconcile
        print(
            f"account {email}: {len(trusted)} Zitadel users with this "
            "verified address or an invite pending, skipped",
            file=sys.stderr,
        )
        return None
    return trusted[0]


pds = config["pds"]


def xrpc(method, nsid, body=None, token=None, query=None):
    path = "/xrpc/" + nsid
    if query:
        path += "?" + urllib.parse.urlencode(query)
    headers = {"Authorization": "Bearer " + token} if token else {}
    return request(pds["url"], method, path, body, headers)


def sql(statement, **variables):
    # psql interpolates :'name' as a quoted literal, in its input only
    args = ["psql", "-X", "-q", "-A", "-t", "-v", "ON_ERROR_STOP=1"]
    for name, value in variables.items():
        args += ["-v", f"{name}={value}"]
    res = subprocess.run(
        args + ["-d", pds["database"]],
        input=statement,
        capture_output=True,
        text=True,
    )
    if res.returncode != 0:
        raise Failed(f"psql: {res.stderr.strip()}")
    return [line.split("|") for line in res.stdout.splitlines() if line]


def linked_did(sub):
    rows = sql(
        "SELECT did FROM external_identities"
        " WHERE provider = :'provider' AND provider_user_id = :'sub';",
        provider=PROVIDER,
        sub=sub,
    )
    return rows[0][0] if rows else None


def create_account(email, user, handle):
    full_handle = f"{handle}.{pds['hostname']}"
    # Existing accounts are only ever found through their link: one with
    # this handle or address but without the link is someone's, the owner
    # links it in the PDS's security settings.
    taken = sql(
        "SELECT handle FROM users"
        " WHERE handle = :'handle' OR lower(email) = lower(:'email');",
        handle=full_handle,
        email=email,
    )
    if taken:
        raise Failed(
            f"not linked to the Zitadel user, but account {taken[0][0]} has "
            "this handle or address"
        )
    token = secrets.token_urlsafe(32)
    # as stored by Tranquil's SSO callback for a signup from its start page
    sql(
        "INSERT INTO sso_pending_registration (token, request_uri, provider,"
        " provider_user_id, provider_username, provider_email,"
        " provider_email_verified)"
        " VALUES (:'token', 'standalone', :'provider', :'sub', :'username',"
        " :'email', true);",
        token=token,
        provider=PROVIDER,
        sub=user["id"],
        username=user["userName"],
        email=email,
    )
    res = request(
        pds["url"],
        "POST",
        "/oauth/sso/complete-registration",
        {"token": token, "handle": handle},
    )
    did = res["did"]
    # The signup's initial app password, otherwise shown once to the user
    # and here to nobody.
    sql(
        "DELETE FROM app_passwords WHERE name = 'bsky.app'"
        " AND user_id = (SELECT id FROM users WHERE did = :'did');",
        did=did,
    )
    print(f"account {email}: created {res['handle']} ({did})")
    return did


def normalize(key):
    # type and key material, without the comment
    return " ".join(key.split()[:2])


def list_keys(did):
    records, cursor = [], None
    while True:
        query = {"repo": did, "collection": COLLECTION, "limit": 100}
        if cursor:
            query["cursor"] = cursor
        res = xrpc("GET", "com.atproto.repo.listRecords", query=query)
        records += res["records"]
        cursor = res.get("cursor")
        if not res["records"] or not cursor:
            return {
                r["uri"].rsplit("/", 1)[1]: normalize(r["value"]["publicKey"])
                for r in records
            }


class Session:
    def __init__(self, did):
        self.did = did

    def __enter__(self):
        password = secrets.token_urlsafe(32)
        password_hash = bcrypt.hashpw(password.encode(), bcrypt.gensalt())
        sql(
            "INSERT INTO app_passwords (user_id, name, password_hash, scopes)"
            " SELECT id, :'name', :'hash', :'scopes' FROM users"
            " WHERE did = :'did'"
            " ON CONFLICT (user_id, name) DO UPDATE"
            " SET password_hash = EXCLUDED.password_hash,"
            " scopes = EXCLUDED.scopes;",
            name=APP_PASSWORD,
            hash=password_hash.decode(),
            scopes=f"atproto repo:{COLLECTION} repo:{PROFILE}",
            did=self.did,
        )
        try:
            res = xrpc("POST", "com.atproto.server.createSession", {
                "identifier": self.did,
                "password": password,
            })
        except Failed:
            self.drop_password()
            raise
        self.access, self.refresh = res["accessJwt"], res["refreshJwt"]
        return self

    def drop_password(self):
        sql(
            "DELETE FROM app_passwords WHERE name = :'name'"
            " AND user_id = (SELECT id FROM users WHERE did = :'did');",
            name=APP_PASSWORD,
            did=self.did,
        )

    def __exit__(self, *exc):
        try:
            xrpc("POST", "com.atproto.server.deleteSession",
                 token=self.access)
        finally:
            self.drop_password()

    def write(self, nsid, body):
        return xrpc("POST", nsid, {"repo": self.did, **body}, self.access)


def load_state():
    try:
        with open(config["stateFile"]) as f:
            return json.load(f)
    except FileNotFoundError:
        return {}


def save_state(state):
    tmp = config["stateFile"] + ".tmp"
    with open(tmp, "w") as f:
        json.dump(state, f, indent=2, sort_keys=True)
    os.rename(tmp, config["stateFile"])


def ensure_profile(email, did):
    # tangled.org only finds accounts (e.g. to add them as collaborators)
    # that have this record; it writes it on the first login otherwise
    try:
        xrpc("GET", "com.atproto.repo.getRecord", query={
            "repo": did, "collection": PROFILE, "rkey": "self",
        })
        return
    except Failed:
        pass
    with Session(did) as session:
        session.write("com.atproto.repo.putRecord", {
            "collection": PROFILE,
            "rkey": "self",
            "record": {
                "$type": PROFILE,
                "createdAt": time.strftime(
                    "%Y-%m-%dT%H:%M:%SZ", time.gmtime()
                ),
            },
        })
    print(f"account {email}: added the Tangled profile")


def reconcile_keys(email, did, ssh_keys, state):
    # rkey -> normalized key of the records this tool created
    managed = state.setdefault(did, {})
    present = list_keys(did)
    for rkey in [r for r in managed if r not in present]:
        # deleted by the user
        del managed[rkey]
    have = set(present.values())
    wanted = {normalize(k): k for k in ssh_keys}
    create = [k for n, k in wanted.items() if n not in have]
    delete = [r for r, n in managed.items() if n not in wanted]
    if not create and not delete:
        return
    with Session(did) as session:
        for key in create:
            parts = key.split(maxsplit=2)
            res = session.write("com.atproto.repo.createRecord", {
                "collection": COLLECTION,
                "record": {
                    "$type": COLLECTION,
                    "name": parts[2] if len(parts) > 2 else parts[0],
                    "publicKey": key,
                    "createdAt": time.strftime(
                        "%Y-%m-%dT%H:%M:%SZ", time.gmtime()
                    ),
                },
            })
            managed[res["uri"].rsplit("/", 1)[1]] = normalize(key)
            save_state(state)
            print(f"account {email}: added key {normalize(key)[:40]}...")
        for rkey in delete:
            session.write("com.atproto.repo.deleteRecord", {
                "collection": COLLECTION,
                "rkey": rkey,
            })
            del managed[rkey]
            save_state(state)
            print(f"account {email}: removed key {rkey}")


wait_for(zitadel["url"], "/admin/v1/healthz", zitadel_headers)
wait_for(pds["url"], "/xrpc/_health")

state = load_state()
failed = False
for email, account in config["accounts"].items():
    try:
        user = zitadel_user(email)
        if user is None:
            continue
        did = linked_did(user["id"])
        if did is None:
            if account["handle"] is None:
                if account["sshKeys"]:
                    raise Failed("no linked account for the SSH keys")
                print(f"account {email}: none yet, signs up on the PDS")
                continue
            did = create_account(email, user, account["handle"])
        if account["handle"] is not None:
            ensure_profile(email, did)
        reconcile_keys(email, did, account["sshKeys"], state)
    except Failed as e:
        print(f"account {email}: {e}", file=sys.stderr)
        failed = True
save_state(state)
sys.exit(1 if failed else 0)
