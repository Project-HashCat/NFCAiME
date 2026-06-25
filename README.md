# NFCAiME Server

这是 NFCAiME 公开仓库中的服务端实现，面向自部署和二次开发使用。

如果你只是想让 NFCAiME 客户端连接自己的服务器，这个分支可以直接使用。它提供客户端需要的基础接口：公钥分发、加密数据接收、读卡记录保存、错误日志接收，以及可选 webhook 转发。

出于公开发布和项目边界考虑，本仓库不会内置任何有关与官方服务器通讯的内容。

如果你需要实现绑定 Bot、刷新卡、私服联动、账号系统或其他自定义功能，请使用 webhook 把解密后的读卡记录转发到你自己的后端处理。

## 功能

- 提供 `/public-key` 给客户端获取 RSA 公钥
- 接收客户端上传到 `/card` 的 RSA 加密 SPAD0 数据
- 把解密后的卡片安全数据保存到本地 SQLite
- 可选转发到你配置的 webhook
- 接收客户端手动上传的加密错误日志 `/debug-log`

## 快速开始

```bash
cd server

python3 -m venv .venv
source .venv/bin/activate
pip install -r requirements.txt

mkdir -p data
openssl genrsa -out data/spad0_private_key.pem 2048
chmod 600 data/spad0_private_key.pem

cp .env.example .env
python server.py
```

最小配置：

```env
CARD_SERVER_HOST=0.0.0.0
CARD_SERVER_PORT=8000
SPAD0_RSA_PRIVATE_KEY_FILE=./data/spad0_private_key.pem
DEBUG_LOG_SECRET=NFCAimeDebugLog-v1

NFCAIME_CARD_WEBHOOK_URL=
NFCAIME_CARD_WEBHOOK_TOKEN=
```

启动后可以检查：

```bash
curl http://127.0.0.1:8000/health
curl http://127.0.0.1:8000/public-key
```

## 客户端服务器地址

如果直接暴露 8000 端口：

```text
http://你的服务器IP:8000/card
```

如果使用反向代理，例如：

```text
https://example.com/aime_reader/card
```

需要确保同级路径可访问：

```text
https://example.com/aime_reader/card
https://example.com/aime_reader/public-key
https://example.com/aime_reader/debug-log
https://example.com/aime_reader/health
```

## Webhook 转发

如果你想把读卡数据交给自己的后端处理，配置：

```env
NFCAIME_CARD_WEBHOOK_URL=https://your-server.example.com/nfcaime/card-webhook
NFCAIME_CARD_WEBHOOK_TOKEN=your-secret-token
```

服务会把解密后的记录转发到该地址。

请求头：

```text
Authorization: Bearer your-secret-token
Content-Type: application/json
```

webhook 返回 JSON 时，会合并进客户端响应。

例如：

```json
{
  "ok": true,
  "code": "YOUR-CARD-CODE",
  "display": [
    {
      "label": "Server",
      "value": "Custom Backend"
    }
  ]
}
```

## API

### GET /health

健康检查。

```json
{
  "ok": true,
  "mode": "public"
}
```

### GET /public-key

返回 RSA 公钥 PEM，客户端会用它加密 SPAD0。

### POST /card

接收客户端上传的读卡数据。

必须包含：

```json
{
  "spad0Encrypted": "base64..."
}
```

服务端不会接受明文 SPAD0。

### POST /debug-log

接收客户端手动上传的加密错误日志。

## 注意事项

- 私钥只放在服务器，不要提交到 Git
- 客户端只需要服务器公钥
- 自定义业务逻辑建议通过 webhook 或独立后端实现
- 生产环境建议只通过 HTTPS 暴露服务
