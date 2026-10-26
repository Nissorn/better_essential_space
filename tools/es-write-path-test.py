#!/usr/bin/env python3
"""Legacy-host card write-path probe: create -> update -> verify -> trash -> hard delete.

Proves the write envelope documented in notes/04-audio-download-and-card-writes.md
(AES-256-ECB-PKCS7 payload + RSA-PKCS1v15-wrapped AES key) against the live API.
Reads the account token, legacy apiKey and claimKey from secrets/ (gitignored).
Creates one scratch card titled "BES scratch card (safe to delete)" and removes it.

Usage: python3 tools/es-write-path-test.py
"""
import base64
import hashlib
import json
import os
import secrets
import subprocess
import sys
import time
import urllib.error
import urllib.request
import uuid

REPO = os.environ.get("BES_REPO", os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
BASE = "https://essential-space.nothingtech.link/essentialSpace"
TOK = json.load(open(f"{REPO}/secrets/es_token.json"))["access_token"]
CLAIM_KEY = json.load(open(f"{REPO}/secrets/es_config_dump.json"))["claimKey"]
API_KEY = open(f"{REPO}/secrets/es_legacy_apikey.txt").read().strip()
CLAIM_PEM = "/tmp/es-claim-key.pem"


def headers():
    ts = str(int(time.time() * 1000))
    return {
        "Authorization": f"Bearer {TOK}",
        "timestamp": ts,
        "auth": hashlib.md5((API_KEY + ts).encode()).hexdigest(),
        "Content-Type": "application/json; charset=UTF-8",
    }


def aes_ecb_encrypt_b64(plaintext, key_b64):
    """Java Cipher 'AES' default = AES/ECB/PKCS5Padding; openssl adds the same PKCS7."""
    key_hex = base64.b64decode(key_b64).hex()
    out = subprocess.run(
        ["openssl", "enc", "-aes-256-ecb", "-K", key_hex, "-nosalt"],
        input=plaintext.encode(), capture_output=True, check=True)
    return base64.b64encode(out.stdout).decode()


def rsa_wrap_b64(data):
    spki = "\n".join(CLAIM_KEY[i:i + 64] for i in range(0, len(CLAIM_KEY), 64))
    with open(CLAIM_PEM, "w") as f:
        f.write(f"-----BEGIN PUBLIC KEY-----\n{spki}\n-----END PUBLIC KEY-----\n")
    out = subprocess.run(
        ["openssl", "pkeyutl", "-encrypt", "-pubin", "-inkey", CLAIM_PEM,
         "-pkeyopt", "rsa_padding_mode:pkcs1"],
        input=data.encode(), capture_output=True, check=True)
    return base64.b64encode(out.stdout).decode()


def post(path, body):
    req = urllib.request.Request(
        f"{BASE}/{path}", json.dumps(body).encode(), headers=headers(), method="POST")
    try:
        with urllib.request.urlopen(req, timeout=30) as r:
            return r.status, json.loads(r.read())
    except urllib.error.HTTPError as e:
        return e.code, json.loads(e.read() or b"{}")


def envelope(device_id, aes_key_b64, cipher_key):
    return {
        "payload": aes_ecb_encrypt_b64(device_id, aes_key_b64),
        "cipherKey": cipher_key,
        "clientVersion": 2,
    }


def main():
    aes_key_b64 = base64.b64encode(secrets.token_bytes(32)).decode()
    cipher_key = rsa_wrap_b64(aes_key_b64)
    device_id = "BES-probe-" + secrets.token_hex(8)
    now_ms = int(time.time() * 1000)
    card_id = str(uuid.uuid4())

    def crr_str(title, summary):
        return json.dumps({
            "cards": {
                "card_id": card_id, "title": title, "summary": summary,
                "type": "RECORDING", "create_time": now_ms, "update_time": now_ms,
                "resource_mask": 0,
            },
            "card_resources": [],
        }, separators=(",", ":"))

    create = envelope(device_id, aes_key_b64, cipher_key)
    create["cards"] = [{
        "cardId": card_id,
        "categoryId": "recording",
        "client_request_response": crr_str("BES scratch card (safe to delete)",
                                           "created by es-write-path-test"),
        "files": [],
        "collectionIds": [],
        "clientCreateTime": now_ms,
        "clientUpdateTime": now_ms,
        "payload": aes_ecb_encrypt_b64("0", aes_key_b64),
        "cipherKey": cipher_key,
    }]
    status, resp = post("storage/card/v1/create", create)
    print(f"CREATE  http={status} code={resp.get('code')} msg={resp.get('msg')}")
    if resp.get("code") != "00000":
        print(json.dumps(resp)[:2000])
        sys.exit(1)

    update = envelope(device_id, aes_key_b64, cipher_key)
    update["cards"] = [{
        "cardId": card_id,
        "client_request_response": crr_str("BES scratch card EDITED TITLE",
                                           "summary edited by es-write-path-test"),
        "files": [],
        "collectionIds": [],
        "clientUpdateTime": int(time.time() * 1000),
        "payload": aes_ecb_encrypt_b64("0", aes_key_b64),
        "cipherKey": cipher_key,
    }]
    status, resp = post("storage/card/v1/update", update)
    print(f"UPDATE  http={status} code={resp.get('code')} msg={resp.get('msg')}")

    status, resp = post("storage/card/v1/list", {"page_no": 1, "page_size": 50, "sinceTime": 0})
    found = None
    for c in (resp.get("data") or {}).get("page_data", []):
        if c["cardId"] == card_id:
            found = json.loads(c["client_request_response"])["cards"]
    if found:
        print(f"VERIFY  title={found['title']!r} summary={found['summary']!r}")
    else:
        print("VERIFY  card NOT FOUND in list after update")

    trash = envelope(device_id, aes_key_b64, cipher_key)
    trash["cards"] = [{"cardId": card_id, "clientUpdateTime": int(time.time() * 1000)}]
    status, resp = post("storage/card/v1/delete", trash)
    print(f"TRASH   http={status} code={resp.get('code')} msg={resp.get('msg')}")

    hard = envelope(device_id, aes_key_b64, cipher_key)
    hard["cardIds"] = [card_id]
    status, resp = post("storage/restore/v1/delete", hard)
    print(f"HARDDEL http={status} code={resp.get('code')} msg={resp.get('msg')}")
    print("cardId:", card_id)


if __name__ == "__main__":
    main()
