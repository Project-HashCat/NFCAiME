import base64
import json
import os
import secrets
import sqlite3
import time
import urllib.error
import urllib.request
from pathlib import Path

from fastapi import FastAPI, HTTPException, Request
from fastapi.responses import JSONResponse, PlainTextResponse
import uvicorn
from Crypto.Cipher import AES, PKCS1_OAEP
from Crypto.Hash import SHA256
from Crypto.PublicKey import RSA


BASE_DIR = Path(__file__).resolve().parent
DATA_DIR = BASE_DIR / "data"
DB_PATH = DATA_DIR / "card_records.sqlite3"
DEBUG_LOG_PATH = DATA_DIR / "debug_logs.ndjson"
DEFAULT_SPAD0_PRIVATE_KEY_PATH = DATA_DIR / "spad0_private_key.pem"
DEBUG_LOG_DEFAULT_SECRET = "NFCAimeDebugLog-v1"


def _load_env_file(path: Path) -> None:
    if not path.exists():
        return
    for raw_line in path.read_text(encoding="utf-8").splitlines():
        line = raw_line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, value = line.split("=", 1)
        key = key.strip()
        value = value.strip().strip('"').strip("'")
        if key and key not in os.environ:
            os.environ[key] = value


_load_env_file(BASE_DIR / ".env")


def _json_dumps(value) -> str:
    return json.dumps(value, ensure_ascii=False, separators=(",", ":"))


def _normalize_hex(name, value, byte_length):
    if value is None:
        return None
    if not isinstance(value, str):
        raise ValueError(f"{name} must be a hexadecimal string")
    normalized = value.replace(" ", "").replace(":", "").lower()
    if len(normalized) != byte_length * 2:
        raise ValueError(
            f"{name} must be exactly {byte_length} bytes ({byte_length * 2} hex characters)"
        )
    try:
        bytes.fromhex(normalized)
    except ValueError as exc:
        raise ValueError(f"{name} must contain hexadecimal characters only") from exc
    return normalized


def _load_spad0_private_key():
    raw_key = os.getenv("SPAD0_RSA_PRIVATE_KEY")
    key_file = os.getenv("SPAD0_RSA_PRIVATE_KEY_FILE")
    if raw_key:
        key_data = raw_key.encode("utf-8")
    else:
        path = Path(key_file) if key_file else DEFAULT_SPAD0_PRIVATE_KEY_PATH
        if not path.exists():
            raise ValueError("SPAD0 RSA private key is not configured")
        key_data = path.read_bytes()
    try:
        return RSA.import_key(key_data)
    except (ValueError, IndexError, TypeError) as exc:
        raise ValueError("SPAD0 RSA private key is invalid") from exc


def _decrypt_spad0_encrypted(value):
    if not isinstance(value, str) or not value.strip():
        raise ValueError("spad0Encrypted must be a non-empty base64 string")
    try:
        ciphertext = base64.b64decode(value, validate=True)
    except ValueError as exc:
        raise ValueError("spad0Encrypted must be base64") from exc
    cipher = PKCS1_OAEP.new(_load_spad0_private_key(), hashAlgo=SHA256)
    try:
        plaintext = cipher.decrypt(ciphertext)
    except ValueError as exc:
        raise ValueError("Could not decrypt spad0Encrypted") from exc
    if len(plaintext) != 16:
        raise ValueError("spad0Encrypted must decrypt to exactly 16 bytes")
    return plaintext.hex()


def _debug_log_key():
    secret = os.getenv("DEBUG_LOG_SECRET", DEBUG_LOG_DEFAULT_SECRET)
    return SHA256.new(secret.encode("utf-8")).digest()


def _decrypt_debug_log_payload(data):
    payload = data.get("payload") if isinstance(data, dict) else None
    if not isinstance(payload, str) or not payload.strip():
        raise ValueError("payload must be a non-empty base64 string")
    try:
        combined = base64.b64decode(payload, validate=True)
    except ValueError as exc:
        raise ValueError("payload must be base64") from exc
    if len(combined) <= 28:
        raise ValueError("payload is too short")
    nonce = combined[:12]
    ciphertext = combined[12:-16]
    tag = combined[-16:]
    cipher = AES.new(_debug_log_key(), AES.MODE_GCM, nonce=nonce)
    try:
        plaintext = cipher.decrypt_and_verify(ciphertext, tag)
    except ValueError as exc:
        raise ValueError("Could not decrypt debug log payload") from exc
    try:
        return json.loads(plaintext.decode("utf-8"))
    except (UnicodeDecodeError, json.JSONDecodeError) as exc:
        raise ValueError("debug log payload is not valid JSON") from exc


def _connect_db():
    DATA_DIR.mkdir(parents=True, exist_ok=True)
    conn = sqlite3.connect(DB_PATH)
    conn.row_factory = sqlite3.Row
    conn.execute(
        """
        CREATE TABLE IF NOT EXISTS card_records (
            code TEXT PRIMARY KEY,
            created_at INTEGER NOT NULL,
            idm TEXT,
            payload_json TEXT NOT NULL
        )
        """
    )
    return conn


def _save_card_record(record):
    with _connect_db() as conn:
        conn.execute(
            """
            INSERT OR REPLACE INTO card_records (code, created_at, idm, payload_json)
            VALUES (?, ?, ?, ?)
            """,
            (
                record["code"],
                record["createdAt"],
                record.get("idm"),
                _json_dumps(record),
            ),
        )


def _forward_to_webhook(record):
    url = os.getenv("NFCAIME_CARD_WEBHOOK_URL", "").strip()
    if not url:
        return None
    body = _json_dumps(record).encode("utf-8")
    headers = {"Content-Type": "application/json; charset=utf-8"}
    token = os.getenv("NFCAIME_CARD_WEBHOOK_TOKEN", "").strip()
    if token:
        headers["Authorization"] = f"Bearer {token}"
    timeout = float(os.getenv("NFCAIME_CARD_WEBHOOK_TIMEOUT", "10"))
    request = urllib.request.Request(url, data=body, headers=headers, method="POST")
    try:
        with urllib.request.urlopen(request, timeout=timeout) as response:
            raw = response.read()
            text = raw.decode("utf-8", errors="replace")
            if response.headers.get_content_type() == "application/json":
                return json.loads(text) if text else {}
            return {"webhookStatus": response.status, "webhookBody": text}
    except urllib.error.HTTPError as exc:
        detail = exc.read().decode("utf-8", errors="replace")
        raise ValueError(f"card webhook returned HTTP {exc.code}: {detail}") from exc
    except (urllib.error.URLError, TimeoutError, json.JSONDecodeError) as exc:
        raise ValueError(f"card webhook failed: {exc}") from exc


def _build_card_record(data, request: Request):
    if data.get("spad0") is not None:
        raise ValueError("plaintext spad0 is not accepted by the public server")
    spad0_encrypted = data.get("spad0Encrypted")
    if spad0_encrypted is None:
        raise ValueError("spad0Encrypted is required")

    idm = _normalize_hex("idm", data.get("idm"), 8)
    record = {
        "code": "PUB" + secrets.token_hex(6).upper(),
        "createdAt": int(time.time()),
        "clientHost": request.client.host if request.client else None,
        "userAgent": request.headers.get("user-agent"),
        "idm": idm,
        "rc": _normalize_hex("rc", data.get("rc"), 16),
        "idBlock": _normalize_hex("idBlock", data.get("idBlock"), 16),
        "ckv": _normalize_hex("ckv", data.get("ckv"), 16),
        "wcnt": _normalize_hex("wcnt", data.get("wcnt"), 16),
        "maca": _normalize_hex("maca", data.get("maca"), 8),
        "companyCode": _normalize_hex("companyCode", data.get("companyCode"), 1),
        "firmwareVersion": _normalize_hex("firmwareVersion", data.get("firmwareVersion"), 1),
        "dfc": _normalize_hex("dfc", data.get("dfc"), 2),
        "spad0EncryptedPresent": True,
        "cardSecurityDataHex": _decrypt_spad0_encrypted(spad0_encrypted),
        "rawClientPayload": data,
    }
    return record


app = FastAPI(title="NFCAiME public server")


@app.get("/health")
async def health():
    return {"ok": True, "mode": "public"}


@app.get("/public-key", response_class=PlainTextResponse)
async def public_key():
    try:
        key = _load_spad0_private_key()
    except ValueError as exc:
        raise HTTPException(status_code=503, detail=str(exc)) from exc
    return key.publickey().export_key().decode("utf-8")


@app.post("/debug-log")
async def receive_debug_log(request: Request):
    try:
        data = await request.json()
    except (json.JSONDecodeError, UnicodeDecodeError):
        raise HTTPException(status_code=400, detail="Invalid JSON")
    try:
        payload = _decrypt_debug_log_payload(data)
    except ValueError as exc:
        raise HTTPException(status_code=422, detail=str(exc)) from exc
    record = {
        "receivedAt": int(time.time()),
        "clientHost": request.client.host if request.client else None,
        "userAgent": request.headers.get("user-agent"),
        "payload": payload,
    }
    DATA_DIR.mkdir(parents=True, exist_ok=True)
    with DEBUG_LOG_PATH.open("a", encoding="utf-8") as file:
        file.write(_json_dumps(record) + "\n")
    return {"ok": True}


@app.post("/card")
@app.post("/refeash-aime")
async def receive_card(request: Request):
    try:
        data = await request.json()
    except (json.JSONDecodeError, UnicodeDecodeError):
        raise HTTPException(status_code=400, detail="Invalid JSON")
    try:
        record = _build_card_record(data, request)
        _save_card_record(record)
        webhook_result = _forward_to_webhook(record)
    except ValueError as exc:
        raise HTTPException(status_code=422, detail=str(exc)) from exc

    response = {
        "ok": True,
        "saved": True,
        "code": record["code"],
        "message": "Card data received",
        "display": [
            {"label": "IDM", "value": record.get("idm") or "-"},
            {"label": "Server", "value": "Public receiver"},
        ],
    }
    if isinstance(webhook_result, dict):
        response.update(webhook_result)
    return response


@app.exception_handler(HTTPException)
async def http_exception_handler(_, exc: HTTPException):
    return JSONResponse(status_code=exc.status_code, content={"detail": exc.detail})


if __name__ == "__main__":
    uvicorn.run(
        app,
        host=os.getenv("CARD_SERVER_HOST", "0.0.0.0"),
        port=int(os.getenv("CARD_SERVER_PORT", "8000")),
    )
