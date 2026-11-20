# Applies lass.zitadel (modules/zitadel/default.nix) to Zitadel through its
# admin and management APIs. Objects are found by name, created when missing
# and updated when they differ. Projects and apps missing from the config
# are left alone.
import hashlib
import json
import os
import pwd
import sys
import time
import urllib.error
import urllib.request

[config_path] = sys.argv[1:]
with open(config_path) as f:
    config = json.load(f)


def request(method, path, body=None, token=None):
    headers = {"Host": config["domain"], "Content-Type": "application/json"}
    if token:
        headers["Authorization"] = "Bearer " + token
    req = urllib.request.Request(
        config["url"] + path,
        method=method,
        headers=headers,
        data=None if body is None else json.dumps(body).encode(),
    )
    with urllib.request.urlopen(req) as res:
        return json.load(res)


# Goes through the HTTP gateway to the gRPC API, which comes up after
# /debug/ready already answers.
while True:
    try:
        request("GET", "/admin/v1/healthz")
        break
    except (urllib.error.URLError, ConnectionError):
        time.sleep(1)

with open(config["patFile"]) as f:
    pat = f.read().strip()


def call(method, path, body=None):
    try:
        return request(method, path, body, pat)
    except urllib.error.HTTPError as e:
        sys.exit(f"{method} {path}: {e.code} {e.read().decode()}")


def search(path, body={}):
    results = []
    while True:
        res = call("POST", path, {**body, "query": {"offset": len(results)}})
        page = res.get("result", [])
        results += page
        total = int(res.get("details", {}).get("totalResult", 0))
        if not page or len(results) >= total:
            return results


def by_name(objects, name):
    return next((o for o in objects if o["name"] == name), None)


# The APIs omit fields with zero values.
ZERO = {
    "appType": "OIDC_APP_TYPE_WEB",
    "authMethodType": "OIDC_AUTH_METHOD_TYPE_BASIC",
    "accessTokenType": "OIDC_TOKEN_TYPE_BEARER",
}


def differs(current, wanted):
    return any(
        current.get(k, ZERO.get(k, False)) != v for k, v in wanted.items()
    )


# SMTP provider (instance), found by its description

if config["smtp"] is not None:
    wanted = {"description": "lass.zitadel", **config["smtp"]}
    with open(wanted.pop("passwordFile")) as f:
        password = f.read().strip()
    # Zitadel never shows the password, so a hash of the one it has is kept
    password_hash = hashlib.sha256(password.encode()).hexdigest()
    state_file = f"{config['stateDir']}/smtp.json"
    saved = {}
    if os.path.exists(state_file):
        with open(state_file) as f:
            saved = json.load(f)
    current = next((
        c for c in search("/admin/v1/smtp/_search")
        if c.get("description") == wanted["description"]
    ), None)
    if current is None:
        smtp_id = call("POST", "/admin/v1/smtp", {
            **wanted,
            "password": password,
        })["id"]
        print("smtp: created")
    else:
        smtp_id = current["id"]
        if differs(current, wanted):
            call("PUT", f"/admin/v1/smtp/{smtp_id}", wanted)
            print("smtp: updated")
        if saved.get(smtp_id) != password_hash:
            call("PUT", f"/admin/v1/smtp/{smtp_id}/password", {
                "password": password,
            })
            print("smtp: new password")
    if saved.get(smtp_id) != password_hash:
        with open(state_file, "w") as f:
            json.dump({smtp_id: password_hash}, f)
    if current is None or current.get("state") != "SMTP_CONFIG_ACTIVE":
        call("POST", f"/admin/v1/smtp/{smtp_id}/_activate", {})
        print("smtp: activated")


# login policy and external IdPs (instance defaults)

policy = call("GET", "/admin/v1/policies/login")["policy"]
wanted = config["loginPolicy"]
if differs(policy, wanted):
    call("PUT", "/admin/v1/policies/login", {**policy, **wanted})

providers = search("/admin/v1/idps/templates/_search")
linked = {
    i["idpId"] for i in search("/admin/v1/policies/login/idps/_search")
}
IDP_PATHS = {"github": "github", "google": "google", "oidc": "generic_oidc"}
for idp in config["idps"].values():
    name = idp["name"]
    client_id = idp["clientId"]
    if client_id is None:
        with open(idp["clientIdFile"]) as f:
            client_id = f.read().strip()
    with open(idp["clientSecretFile"]) as f:
        client_secret = f.read().strip()
    if not client_id or not client_secret:
        print(f"idp {name}: no credentials, skipped")
        continue
    body = {
        "name": name,
        "clientId": client_id,
        "clientSecret": client_secret,
        "scopes": idp["scopes"],
        "providerOptions": idp["providerOptions"],
    }
    if idp["type"] == "oidc":
        body |= {
            "issuer": idp["issuer"],
            # user info from the ID token, without a userinfo request
            "isIdTokenMapping": True,
            "usePkce": True,
        }
    path = f"/admin/v1/idps/{IDP_PATHS[idp['type']]}"
    existing = by_name(providers, name)
    if existing:
        idp_id = existing["id"]
        call("PUT", f"{path}/{idp_id}", body)
    else:
        idp_id = call("POST", path, body)["id"]
        print(f"idp {name}: created")
    if idp_id not in linked:
        call("POST", "/admin/v1/policies/login/idps", {"idpId": idp_id})
        print(f"idp {name}: added to the login policy")


# Flat "groups" claim (default organization): role keys of the requesting
# app's project, for clients that can't read the object in
# urn:zitadel:iam:org:project:roles (oauth2-proxy's --allowed-group).

action = {
    # also the name of the script's function
    "name": "groupsClaim",
    "script": config["groupsClaimScript"],
    # a failing or slow script must never block a login
    "timeout": "5s",
    "allowedToFail": True,
}
existing = by_name(search("/management/v1/actions/_search"), action["name"])
if existing is None:
    action_id = call("POST", "/management/v1/actions", action)["id"]
    print(f"action {action['name']}: created")
else:
    action_id = existing["id"]
    if differs(existing, action):
        call("PUT", f"/management/v1/actions/{action_id}", action)
        print(f"action {action['name']}: updated")
    if existing.get("state") != "ACTION_STATE_ACTIVE":
        call("POST", f"/management/v1/actions/{action_id}/_reactivate", {})
        print(f"action {action['name']}: reactivated")

# Complement Token flow; pre userinfo creation (userinfo, ID tokens,
# introspection) and pre access token creation (JWT access tokens).
# Setting a trigger replaces its list, so other actions on it are kept.
COMPLEMENT_TOKEN = "2"
flow = call("GET", f"/management/v1/flows/{COMPLEMENT_TOKEN}")["flow"]
triggers = {
    t["triggerType"]["id"]: [a["id"] for a in t.get("actions", [])]
    for t in flow.get("triggerActions", [])
}
for trigger in ["4", "5"]:
    ids = triggers.get(trigger, [])
    if action_id not in ids:
        path = f"/management/v1/flows/{COMPLEMENT_TOKEN}/trigger/{trigger}"
        call("POST", path, {"actionIds": ids + [action_id]})
        print(f"action {action['name']}: added to trigger {trigger}")


# projects, OIDC apps and user grants (default organization)

def find_user(email, invite):
    # Anyone can register with any address and any free username, including
    # one that looks like someone's address. Trusted are users who verified
    # theirs, or who were created by an admin and have no login yet (as
    # zitadel-invite does).
    method = "TEXT_QUERY_METHOD_EQUALS_IGNORE_CASE"
    users = search("/management/v1/users/_search", {"queries": [
        {"emailQuery": {"emailAddress": email, "method": method}},
        {"typeQuery": {"type": "TYPE_HUMAN"}},
    ]})
    trusted = [
        u for u in users
        if u["human"].get("email", {}).get("isEmailVerified")
        or u.get("state") == "USER_STATE_INITIAL"
    ]
    if len(trusted) == 1:
        return trusted[0]["id"]
    if not users and invite is not None:
        return invite_user(email, invite)
    print(f"user {email}: {len(trusted)} matches, skipped", file=sys.stderr)
    return None


def invite_user(email, application_name):
    # verified by the invite code, without a separate mail
    org_id = call("GET", "/management/v1/orgs/me")["org"]["id"]
    given = email.split("@")[0]
    user_id = call("POST", "/v2/users/new", {
        "organizationId": org_id,
        "human": {
            "profile": {
                "givenName": given,
                # Zitadel requires one
                "familyName": given,
                "displayName": given,
            },
            "email": {"email": email, "returnCode": {}},
        },
    })["id"]
    call("POST", f"/v2/users/{user_id}/invite_code", {
        "sendCode": {"applicationName": application_name},
    })
    print(f"user {email}: created, invite mail sent")
    return user_id


def write_file(path, uid, content):
    tmp = path + ".tmp"
    fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o400)
    with os.fdopen(fd, "w") as f:
        f.write(content)
    os.chown(tmp, uid, -1)
    os.rename(tmp, path)


projects = search("/management/v1/projects/_search")
for project_name, project in config["projects"].items():
    settings = {
        "projectRoleCheck": project["access"] != "public",
        "projectRoleAssertion": project["roles"] != [],
    }
    existing = by_name(projects, project_name)
    if existing is None:
        project_id = call("POST", "/management/v1/projects", {
            "name": project_name,
            **settings,
        })["id"]
        print(f"project {project_name}: created")
    else:
        project_id = existing["id"]
        if differs(existing, settings):
            call("PUT", f"/management/v1/projects/{project_id}", {
                **existing,
                **settings,
            })
            print(f"project {project_name}: {settings}")

    roles = f"/management/v1/projects/{project_id}/roles"
    have = {r["key"] for r in search(f"{roles}/_search")}
    for role in project["roles"]:
        if role not in have:
            call("POST", roles, {"roleKey": role, "displayName": role})
            print(f"project {project_name}: role {role} created")

    base = f"/management/v1/projects/{project_id}/apps"
    apps = search(f"{base}/_search")
    for app_name, app in project["apps"].items():
        oidc_config = {
            "redirectUris": app["redirectUris"],
            "responseTypes": ["OIDC_RESPONSE_TYPE_CODE"],
            "grantTypes": app["grantTypes"],
            "appType": "OIDC_APP_TYPE_WEB",
            "authMethodType": app["authMethodType"],
            "accessTokenType": app["accessTokenType"],
        }
        state_file = f"{config['stateDir']}/{project_name}-{app_name}.json"
        secret = None
        existing = by_name(apps, app_name)
        if existing is None:
            new = {"name": app_name, **oidc_config}
            res = call("POST", f"{base}/oidc", new)
            app_id, client_id = res["appId"], res["clientId"]
            secret = res.get("clientSecret")
            print(f"app {project_name}/{app_name}: created")
        else:
            app_id = existing["id"]
            client_id = existing["oidcConfig"]["clientId"]
            if differs(existing["oidcConfig"], oidc_config):
                call("PUT", f"{base}/{app_id}/oidc_config", oidc_config)
                print(f"app {project_name}/{app_name}: updated")
            if os.path.exists(state_file):
                with open(state_file) as f:
                    saved = json.load(f)
                if saved["clientId"] == client_id:
                    secret = saved["clientSecret"]
        # Zitadel shows a secret only when it creates it, so without a saved
        # copy for this client the app gets a new one. Public clients have
        # none.
        public = app["authMethodType"] == "OIDC_AUTH_METHOD_TYPE_NONE"
        if secret is None and not public:
            path = f"{base}/{app_id}/oidc_config/_generate_client_secret"
            secret = call("POST", path, {})["clientSecret"]
            print(f"app {project_name}/{app_name}: new client secret")
        write_file(state_file, 0, json.dumps({
            "clientId": client_id,
            "clientSecret": secret,
        }))
        env = app["envFile"]
        uid = pwd.getpwnam(env["owner"]).pw_uid
        content = f"{env['clientIdVariable']}={client_id}\n"
        if not public:
            content += f"{env['clientSecretVariable']}={secret}\n"
        write_file(env["path"], uid, content)
        write_file(app["clientIdFile"], uid, client_id)

    if project["access"] != "declarative":
        continue
    users = {
        find_user(name, project["invite"]): name for name in project["users"]
    }
    users.pop(None, None)
    grants = search("/management/v1/users/grants/_search", {"queries": [
        {"projectIdQuery": {"projectId": project_id}},
    ]})
    for grant in grants:
        if grant["userId"] in users:
            del users[grant["userId"]]
        else:
            call(
                "DELETE",
                f"/management/v1/users/{grant['userId']}/grants/{grant['id']}",
            )
            print(f"project {project_name}: revoked {grant['userName']}")
    for user_id, name in users.items():
        call("POST", f"/management/v1/users/{user_id}/grants", {
            "projectId": project_id,
        })
        print(f"project {project_name}: granted {name}")
