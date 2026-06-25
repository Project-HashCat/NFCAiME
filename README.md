# NFCAiME Public Server

This public server is a neutral receiver for NFCAiME clients.

It intentionally does not include:

- Official AiMeDB connectivity
- CMD17/AiMeDB protocol implementation
- SPAD0 access-code decoding tables or algorithms
- Built-in bot binding logic

It provides:

- `GET /health`
- `GET /public-key`
- `POST /card`
- `POST /refeash-aime` for compatibility with older clients
- `POST /debug-log`

`POST /card` accepts RSA-encrypted card security data from the app, decrypts it
with the server private key, stores the received record locally, and optionally
forwards the decrypted record to your own webhook.

See `server/.env.example` for configuration.
