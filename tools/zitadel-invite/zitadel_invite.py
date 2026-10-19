# Invites a person to projects of a Zitadel organization: creates a human
# user for the email address (username = the address), lets Zitadel mail
# them an invite code to set up a password, and adds a user grant on each
# project. An existing user with that address only gets the missing grants.
import argparse
import json
import os
import sys
import urllib.error
import urllib.request

parser = argparse.ArgumentParser(
    prog="zitadel-invite",
    description="Invite a person to Zitadel projects.",
    epilog="It needs the token of a user with the ORG_USER_MANAGER role.",
)
parser.add_argument("email")
parser.add_argument("projects", nargs="+", metavar="project")
parser.add_argument("--name", help='"First Last", default: the local part')
parser.add_argument(
    "--resend",
    action="store_true",
    help="send a new invite code to an existing user who has not set up "
    "a login yet",
)
parser.add_argument(
    "--app-name", help="application name in the invite mail"
)
parser.add_argument(
    "--url",
    default=os.environ.get("ZITADEL_URL"),
    help="Zitadel URL, e.g. https://id.example.org (env ZITADEL_URL)",
)
parser.add_argument(
    "--token-file",
    default=os.environ.get("ZITADEL_TOKEN_FILE"),
    help="file with a personal access token (env ZITADEL_TOKEN_FILE, or "
    "the token itself in ZITADEL_TOKEN)",
)
args = parser.parse_args()

if not args.url:
    parser.error("--url or ZITADEL_URL is needed")
if args.token_file:
    with open(args.token_file) as f:
        token = f.read().strip()
else:
    token = os.environ.get("ZITADEL_TOKEN")
if not token:
    parser.error("--token-file, ZITADEL_TOKEN_FILE or ZITADEL_TOKEN is needed")
issuer = args.url.rstrip("/")


def fetch(req, what):
    try:
        with urllib.request.urlopen(req) as res:
            return json.load(res)
    except urllib.error.HTTPError as e:
        sys.exit(f"{what}: {e.code} {e.read().decode()}")


def call(method, path, body=None):
    return fetch(urllib.request.Request(
        issuer + path,
        method=method,
        headers={
            "Authorization": "Bearer " + token,
            "Content-Type": "application/json",
        },
        data=None if body is None else json.dumps(body).encode(),
    ), f"{method} {path}")


def invite(user_id):
    send_code = {}
    if args.app_name:
        send_code["applicationName"] = args.app_name
    call("POST", f"/v2/users/{user_id}/invite_code", {"sendCode": send_code})
    print(f"user {args.email}: invite mail sent")


# check the projects before changing anything
project_ids = {}
for name in args.projects:
    found = [
        p for p in call("POST", "/management/v1/projects/_search", {
            "queries": [{"nameQuery": {
                "name": name,
                "method": "TEXT_QUERY_METHOD_EQUALS",
            }}],
        }).get("result", [])
        if p["name"] == name
    ]
    if len(found) != 1:
        sys.exit(f"project {name}: {len(found)} matches")
    project_ids[name] = found[0]["id"]

users = call("POST", "/management/v1/users/_search", {"queries": [
    {"emailQuery": {
        "emailAddress": args.email,
        "method": "TEXT_QUERY_METHOD_EQUALS_IGNORE_CASE",
    }},
    {"typeQuery": {"type": "TYPE_HUMAN"}},
]}).get("result", [])
if len(users) > 1:
    sys.exit(f"user {args.email}: {len(users)} users with this address")

if users:
    user = users[0]
    user_id = user["id"]
    # Anyone can register with any address. Grants go only to users who
    # verified theirs, or who were created by an admin and have no login yet.
    initial = user.get("state") == "USER_STATE_INITIAL"
    verified = user["human"].get("email", {}).get("isEmailVerified", False)
    if not initial and not verified:
        sys.exit(
            f"user {args.email}: exists ({user['userName']}) with the "
            "address unverified, not granting"
        )
    print(f"user {args.email}: exists ({user['userName']})")
    if args.resend:
        if initial:
            invite(user_id)
        else:
            print(f"user {args.email}: has a login already, no invite")
else:
    full_name = args.name or args.email.split("@")[0]
    given, _, family = full_name.partition(" ")
    org_id = call("GET", "/management/v1/orgs/me")["org"]["id"]
    user_id = call("POST", "/v2/users/new", {
        "organizationId": org_id,
        "human": {
            "profile": {
                "givenName": given,
                # Zitadel requires one
                "familyName": family.strip() or given,
                "displayName": full_name,
            },
            # verified by the invite code, without a separate mail
            "email": {"email": args.email, "returnCode": {}},
        },
    })["id"]
    print(f"user {args.email}: created")
    invite(user_id)

granted = {
    g["projectId"]
    for g in call("POST", "/management/v1/users/grants/_search", {
        "queries": [{"userIdQuery": {"userId": user_id}}],
    }).get("result", [])
}
for name, project_id in project_ids.items():
    if project_id in granted:
        print(f"project {name}: granted already")
    else:
        call("POST", f"/management/v1/users/{user_id}/grants", {
            "projectId": project_id,
        })
        print(f"project {name}: granted")
