"""Applies Wiki.js configuration that cannot live in the manifests.

Wiki.js keeps its OIDC strategy, groups and page rules in the database, so this
runs after the deployment is up and pushes them over GraphQL. Every step is
written to be safe on an instance that is already configured, because Flux
recreates this Job whenever its spec changes.
"""

import base64
import json
import os
import secrets
import ssl
import sys
import time
import urllib.error
import urllib.request

WIKI = os.environ["WIKI_URL"].rstrip("/")      # in-cluster service
SITE_URL = os.environ["SITE_URL"].rstrip("/")  # public URL wiki.js records
ADMIN_EMAIL = os.environ["ADMIN_EMAIL"]
ADMIN_SECRET = os.environ["ADMIN_SECRET"]
OIDC_CLIENT_ID = os.environ["OIDC_CLIENT_ID"]
OIDC_CLIENT_SECRET = os.environ["OIDC_CLIENT_SECRET"]
OIDC_ISSUER = os.environ["OIDC_ISSUER"]
API_KEY_SECRET = os.environ["API_KEY_SECRET"]
NAMESPACE = os.environ["NAMESPACE"]
SECRET_PATH = "/api/v1/namespaces/%s/secrets" % NAMESPACE

# Wiki.js builds its callback path from the strategy key, and the authentik
# blueprint pins the matching redirect URI, so this cannot be regenerated.
OIDC_KEY = "a19a8034-8514-4578-af66-dc085d2334d1"

# Built-in group, id fixed by the installer.
GUESTS_GROUP_ID = 2

# Base groups only. Per-campaign groups and page rules belong to the campaign
# service so that exactly one writer owns them.
BASE_GROUPS = {
    "mapper": {
        "permissions": ["read:pages", "read:assets", "read:comments"],
        "rules": [{"id": "handbook", "path": "handbook/",
                   "roles": ["read:pages", "read:assets"]}],
    },
    "mapper-admin": {
        "permissions": ["manage:system"],
        "rules": [{"id": "admin-all", "path": "",
                   "roles": ["read:pages", "write:pages", "manage:pages"]}],
    },
}


def log(msg):
    print(msg, flush=True)


def post(path, payload, token=None):
    body = json.dumps(payload).encode()
    headers = {"Content-Type": "application/json"}
    if token:
        headers["Authorization"] = "Bearer " + token
    req = urllib.request.Request(WIKI + path, data=body, headers=headers)
    with urllib.request.urlopen(req, timeout=30) as resp:
        return json.loads(resp.read() or "{}")


def graphql(query, token, variables=None):
    out = post("/graphql", {"query": query, "variables": variables or {}}, token)
    if "errors" in out:
        raise RuntimeError(json.dumps(out["errors"]))
    return out["data"]


def wait_for_wiki():
    for attempt in range(60):
        try:
            urllib.request.urlopen(WIKI + "/healthz", timeout=5).read()
            return
        except Exception:
            time.sleep(5)
    raise RuntimeError("wiki.js did not become healthy")


def login_as(password):
    query = """mutation ($u: String!, $p: String!) {
      authentication { login(username: $u, password: $p, strategy: "local") {
        jwt responseResult { succeeded message } } } }"""
    result = graphql(query, None, {"u": ADMIN_EMAIL, "p": password})["authentication"]["login"]
    if not result["responseResult"]["succeeded"]:
        raise RuntimeError(result["responseResult"]["message"])
    return result["jwt"]


def login():
    """Returns an admin JWT, creating the local account on a fresh instance.

    Wiki.js will not let the local administrator be deleted or deactivated, so
    it always exists. Nobody is expected to use it, so rather than tracking a
    password in git it is generated here and kept in a Secret as break-glass
    access for when OIDC is broken.
    """
    stored = read_secret(ADMIN_SECRET) or {}
    if "adminPassword" in stored:
        log("using stored admin credential")
        return login_as(stored["adminPassword"])

    if not in_setup_mode():
        raise RuntimeError(
            "wiki.js is already set up but no admin credential is stored. "
            "Put the existing password in secret %s under adminPassword to "
            "adopt this instance." % ADMIN_SECRET)

    # 48 bytes encodes to exactly 64 url-safe characters, and stays under
    # bcrypt's 72 byte input limit so none of it is silently truncated.
    password = secrets.token_urlsafe(48)
    # Stored before it is used: a finalize that succeeded without the password
    # being written down would lock everyone out permanently.
    write_secret(ADMIN_SECRET, {"adminPassword": password})
    post("/finalize", {
        "adminEmail": ADMIN_EMAIL,
        "adminPassword": password,
        "adminPasswordConfirm": password,
        "siteUrl": SITE_URL,
        "telemetry": False,
    })
    log("finalized install and stored generated admin credential")
    time.sleep(10)  # wiki.js restarts itself after finalize
    wait_for_wiki()
    return login_as(password)


def apply_oidc(token):
    """updateStrategies is a full replace, so local auth is sent alongside.

    authentik is ordered ahead of local because auto-login redirects to the
    lowest-ordered strategy and only when that one is not form-based. With
    local first the redirect is silently skipped and the login page renders
    instead. Local is parked at 99 rather than 1 so that anything added later
    still sorts ahead of it and the redirect keeps working.
    """
    # Endpoints come from the provider's discovery document rather than being
    # built off the issuer. authentik serves authorize, token and userinfo from
    # /application/o/ while only end-session sits under the application slug, so
    # deriving them from the issuer produces URLs that 404.
    disco = json.loads(urllib.request.urlopen(
        OIDC_ISSUER + ".well-known/openid-configuration", timeout=30).read())

    query = """mutation ($s: [AuthenticationStrategyInput]!) {
      authentication { updateStrategies(strategies: $s) {
        responseResult { succeeded message } } } }"""
    strategies = [
        {"key": "local", "strategyKey": "local", "displayName": "Local",
         "order": 99, "isEnabled": True, "config": [],
         "selfRegistration": False, "domainWhitelist": [], "autoEnrollGroups": []},
        {"key": OIDC_KEY, "strategyKey": "oidc", "displayName": "authentik",
         "order": 0, "isEnabled": True, "selfRegistration": True,
         "domainWhitelist": [], "autoEnrollGroups": [],
         "config": [
             {"key": "clientId", "value": json.dumps({"v": OIDC_CLIENT_ID})},
             {"key": "clientSecret", "value": json.dumps({"v": OIDC_CLIENT_SECRET})},
             {"key": "authorizationURL", "value": json.dumps({"v": disco["authorization_endpoint"]})},
             {"key": "tokenURL", "value": json.dumps({"v": disco["token_endpoint"]})},
             {"key": "userInfoURL", "value": json.dumps({"v": disco["userinfo_endpoint"]})},
             {"key": "issuer", "value": json.dumps({"v": disco["issuer"]})},
             {"key": "emailClaim", "value": json.dumps({"v": "email"})},
             {"key": "displayNameClaim", "value": json.dumps({"v": "name"})},
             {"key": "mapGroups", "value": json.dumps({"v": True})},
             {"key": "groupsClaim", "value": json.dumps({"v": "groups"})},
             {"key": "logoutURL", "value": json.dumps({"v": disco.get("end_session_endpoint", "")})},
         ]},
    ]
    graphql(query, token, {"s": strategies})
    log("applied oidc strategy at pinned key")


def ensure_groups(token):
    existing = graphql("{ groups { list { id name } } }", token)["groups"]["list"]
    by_name = {g["name"]: g["id"] for g in existing}

    for name, spec in BASE_GROUPS.items():
        if name not in by_name:
            created = graphql(
                """mutation ($n: String!) { groups { create(name: $n) {
                   group { id } responseResult { succeeded message } } } }""",
                token, {"n": name})
            by_name[name] = created["groups"]["create"]["group"]["id"]
            log("created group %s" % name)

        # These base groups are owned here outright: their rules are replaced
        # rather than merged. groups.create() seeds a "default" rule granting
        # read on path "", and preserving it would give every member of every
        # campaign read access to all of them.
        current = graphql(
            """query ($id: Int!) { groups { single(id: $id) {
               id name redirectOnLogin } } }""",
            token, {"id": by_name[name]})["groups"]["single"]

        rules = [{"id": r["id"], "deny": False, "match": "START",
                  "path": r["path"], "roles": r["roles"], "locales": []}
                 for r in spec["rules"]]

        graphql(
            """mutation ($id: Int!, $n: String!, $r: String!, $p: [String]!,
                         $pr: [PageRuleInput]!) {
               groups { update(id: $id, name: $n, redirectOnLogin: $r,
                               permissions: $p, pageRules: $pr) {
                 responseResult { succeeded message } } } }""",
            token, {"id": by_name[name], "n": current["name"],
                    "r": current["redirectOnLogin"] or "/",
                    "p": spec["permissions"], "pr": rules})
        log("applied page rules for %s" % name)


def secure_guests(token):
    """Removes the allow rule Wiki.js ships on the built-in Guests group.

    A fresh install grants Guests read on path "" with match START, which makes
    the entire wiki readable anonymously. Campaign isolation depends on no group
    holding a global read rule, so this is stripped rather than asserted -- it is
    present on every new install.
    """
    current = graphql(
        """query ($id: Int!) { groups { single(id: $id) {
           id name redirectOnLogin permissions
           pageRules { id deny match path roles locales } } } }""",
        token, {"id": GUESTS_GROUP_ID})["groups"]["single"]

    rules = current["pageRules"] or []
    kept = [r for r in rules if r["deny"]]
    if len(kept) == len(rules):
        log("guests group already has no allow rule")
        return

    graphql(
        """mutation ($id: Int!, $n: String!, $r: String!, $p: [String]!,
                     $pr: [PageRuleInput]!) {
           groups { update(id: $id, name: $n, redirectOnLogin: $r,
                           permissions: $p, pageRules: $pr) {
             responseResult { succeeded message } } } }""",
        token, {"id": GUESTS_GROUP_ID, "n": current["name"],
                "r": current["redirectOnLogin"] or "/", "p": [],
                "pr": [{"id": r["id"], "deny": True, "match": r["match"],
                        "path": r["path"], "roles": r["roles"],
                        "locales": r["locales"] or []} for r in kept]})
    log("removed %d allow rule(s) from Guests" % (len(rules) - len(kept)))


def apply_site_config(token):
    """Makes authentik the only advertised way in.

    hideLocal is a render flag on the login page, not server-side enforcement,
    so the local strategy keeps working for break-glass -- recovery is the same
    login(strategy: "local") call this script makes, using the password from the
    admin Secret. autoLogin skips the provider picker; /login?all=1 still
    reaches the picker if it is ever needed.
    """
    graphql(
        """mutation ($hide: Boolean!, $auto: Boolean!) {
           site { updateConfig(authHideLocal: $hide, authAutoLogin: $auto) {
             responseResult { succeeded message } } } }""",
        token, {"hide": True, "auto": True})
    log("hid local login and enabled auto-login to the provider")


def ensure_api_key(token):
    """Mints the campaign-service key only when absent; it is shown once."""
    keys = graphql("{ authentication { apiKeys { id name isRevoked } } }",
                   token)["authentication"]["apiKeys"] or []
    if any(k["name"] == "campaign-service" and not k["isRevoked"] for k in keys):
        log("campaign-service api key already present, leaving it alone")
        return

    graphql("""mutation { authentication { setApiState(enabled: true) {
              responseResult { succeeded message } } } }""", token)
    created = graphql(
        """mutation { authentication { createApiKey(
             name: "campaign-service", expiration: "1y", fullAccess: true) {
               key responseResult { succeeded message } } } }""", token)
    write_secret(API_KEY_SECRET,
                 {"apiKey": created["authentication"]["createApiKey"]["key"]})
    log("minted campaign-service api key and stored it")


def k8s_request(path, method="GET", body=None):
    token = open("/var/run/secrets/kubernetes.io/serviceaccount/token").read()
    ctx = ssl.create_default_context(
        cafile="/var/run/secrets/kubernetes.io/serviceaccount/ca.crt")
    req = urllib.request.Request(
        "https://kubernetes.default.svc" + path,
        data=json.dumps(body).encode() if body is not None else None,
        method=method,
        headers={"Authorization": "Bearer " + token,
                 "Content-Type": "application/json"})
    with urllib.request.urlopen(req, context=ctx, timeout=30) as resp:
        return json.loads(resp.read() or "{}")


def read_secret(name):
    """Returns the Secret's decoded data, or None when it does not exist."""
    try:
        out = k8s_request(SECRET_PATH + "/" + name)
    except urllib.error.HTTPError as err:
        if err.code == 404:
            return None
        raise
    return {k: base64.b64decode(v).decode()
            for k, v in (out.get("data") or {}).items()}


def write_secret(name, data):
    body = {"apiVersion": "v1", "kind": "Secret", "metadata": {"name": name},
            "type": "Opaque",
            "data": {k: base64.b64encode(v.encode()).decode()
                     for k, v in data.items()}}
    try:
        k8s_request(SECRET_PATH, "POST", body)
    except urllib.error.HTTPError as err:
        if err.code != 409:
            raise
        k8s_request(SECRET_PATH + "/" + name, "PUT", body)


def in_setup_mode():
    """An un-finalized Wiki.js serves the setup wizard from every path."""
    with urllib.request.urlopen(WIKI + "/", timeout=15) as resp:
        return b"<title>Wiki.js Setup</title>" in resp.read()


def main():
    wait_for_wiki()
    token = login()
    apply_oidc(token)
    ensure_groups(token)
    secure_guests(token)
    apply_site_config(token)
    ensure_api_key(token)
    log("bootstrap complete")


if __name__ == "__main__":
    try:
        main()
    except Exception as err:
        log("bootstrap failed: %s" % err)
        sys.exit(1)
