import json
OUT = "/tmp/flow_bodies.jsonl"
def response(flow):
    try:
        req = flow.request
        if "account.nothing.tech" not in req.pretty_host:
            return
        p = req.path
        if not any(k in p for k in ("me_v2", "authflow/login", "oauth2/token", "mfa")):
            return
        rec = {
            "path": p[:120],
            "method": req.method,
            "status": flow.response.status_code if flow.response else None,
            "req_body": (req.content or b"")[:2000].decode("utf-8", "replace"),
            "resp_body": (flow.response.content or b"")[:6000].decode("utf-8", "replace") if flow.response else "",
        }
        with open(OUT, "a") as f:
            f.write(json.dumps(rec) + "\n")
    except Exception as e:
        pass
