# mitmdump addon: dump request summary of recent flows to a jsonl file
import json, time
OUT = "/tmp/flow_recent.jsonl"
CUTOFF = time.time() - 3600  # last hour

def load(l):
    pass

def response(flow):
    try:
        if flow.timestamp_start < CUTOFF:
            return
        req = flow.request
        rec = {
            "t": flow.timestamp_start,
            "method": req.method,
            "host": req.pretty_host,
            "path": req.path,
            "status": flow.response.status_code if flow.response else None,
            "auth": (req.headers.get("authorization", "")[:28] + "...") if req.headers.get("authorization") else None,
            "ctype": req.headers.get("content-type", ""),
            "req_len": len(req.content or b""),
            "resp_ct": flow.response.headers.get("content-type", "") if flow.response else "",
            "resp_len": len(flow.response.content or b"") if flow.response else 0,
        }
        with open(OUT, "a") as f:
            f.write(json.dumps(rec) + "\n")
    except Exception as e:
        with open(OUT, "a") as f:
            f.write(json.dumps({"err": str(e)}) + "\n")
