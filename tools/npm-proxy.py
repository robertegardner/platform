#!/usr/bin/env python3
"""npm-proxy — automate NPMplus proxy-host repoints (cutover helper).

NPMplus (Nginx Proxy Manager fork) exposes the standard NPM REST API on the
admin port (:81). Auth: POST /api/tokens with an admin identity/secret yields
a short-lived JWT; proxy hosts are CRUD at /api/nginx/proxy-hosts.

Usage:
  npm-proxy.py list
  npm-proxy.py repoint <domain> <forward_host> <forward_port>

Credentials come from the environment (never commit them):
  NPM_URL       default https://192.168.6.49:81
  NPM_IDENTITY  admin email
  NPM_SECRET    admin password
e.g. keep them in ~/.config/npm-proxy.env (chmod 600) and run:
  set -a; . ~/.config/npm-proxy.env; set +a; tools/npm-proxy.py list

Self-signed admin cert -> TLS verification is disabled for this host.
"""
import json
import os
import ssl
import sys
import urllib.request

NPM_URL = os.environ.get("NPM_URL", "https://192.168.6.49:81").rstrip("/")
CTX = ssl.create_default_context()
CTX.check_hostname = False
CTX.verify_mode = ssl.CERT_NONE


def api(path, method="GET", body=None, token=None):
    req = urllib.request.Request(
        NPM_URL + path,
        data=json.dumps(body).encode() if body is not None else None,
        method=method,
        headers={"Content-Type": "application/json",
                 **({"Authorization": f"Bearer {token}"} if token else {})},
    )
    with urllib.request.urlopen(req, timeout=10, context=CTX) as resp:
        return json.loads(resp.read().decode() or "null")


def get_token():
    ident, secret = os.environ.get("NPM_IDENTITY"), os.environ.get("NPM_SECRET")
    if not ident or not secret:
        sys.exit("set NPM_IDENTITY and NPM_SECRET in the environment "
                 "(see header; keep them in ~/.config/npm-proxy.env)")
    return api("/api/tokens", "POST", {"identity": ident, "secret": secret})["token"]


# Fields the PUT endpoint accepts back (strip ids/timestamps/computed).
EDITABLE = [
    "domain_names", "forward_scheme", "forward_host", "forward_port",
    "certificate_id", "ssl_forced", "hsts_enabled", "hsts_subdomains",
    "http2_support", "block_exploits", "caching_enabled",
    "allow_websocket_upgrade", "access_list_id", "advanced_config",
    "enabled", "meta", "locations",
]


def main():
    args = sys.argv[1:]
    if not args or args[0] not in ("list", "repoint"):
        sys.exit(__doc__)
    token = get_token()
    hosts = api("/api/nginx/proxy-hosts", token=token)

    if args[0] == "list":
        for h in hosts:
            print(f"{h['id']:>3}  {','.join(h['domain_names']):<28} -> "
                  f"{h['forward_scheme']}://{h['forward_host']}:{h['forward_port']}"
                  f"{'' if h.get('enabled') else '  [DISABLED]'}")
        return

    domain, fhost, fport = args[1], args[2], int(args[3])
    matches = [h for h in hosts if domain in h["domain_names"]]
    if len(matches) != 1:
        sys.exit(f"{len(matches)} proxy hosts match {domain!r} — refusing")
    h = matches[0]
    old = f"{h['forward_host']}:{h['forward_port']}"
    payload = {k: h[k] for k in EDITABLE if k in h}
    payload["forward_host"], payload["forward_port"] = fhost, fport
    api(f"/api/nginx/proxy-hosts/{h['id']}", "PUT", payload, token=token)
    print(f"{domain}: {old} -> {fhost}:{fport}")


if __name__ == "__main__":
    main()
