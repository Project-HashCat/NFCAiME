# NFCAiME Public Server

> <strong>出于公开发布和项目边界考虑，本仓库不会内置任何有关与官方服务器通讯的内容与计算逻辑</strong>

这个服务端只负责接收客户端上传的加密卡片数据、保存记录、接收错误日志，并按需转发到你自己的 webhook

## 快速开始

```bash
python3 -m venv .venv
source .venv/bin/activate
pip install -r requirements.txt

mkdir -p data
openssl genrsa -out data/spad0_private_key.pem 2048
chmod 600 data/spad0_private_key.pem

cp .env.example .env
python server.py
```

## 最小配置

```env
CARD_SERVER_HOST=0.0.0.0
CARD_SERVER_PORT=8000
SPAD0_RSA_PRIVATE_KEY_FILE=./data/spad0_private_key.pem
DEBUG_LOG_SECRET=NFCAimeDebugLog-v1
NFCAIME_CARD_WEBHOOK_URL=
NFCAIME_CARD_WEBHOOK_TOKEN=
```

## 接口

- `GET /health`
- `GET /public-key`
- `POST /card`
- `POST /debug-log`

客户端服务器地址填写 `/card` 入口，例如：

```text
https://example.com/aime_reader/card
```

同级路径需要能访问 `/public-key`、`/debug-log` 和 `/health`

## Webhook

如需实现账号、Bot、私服联动或其他自定义功能，将业务逻辑放在你自己的后端，然后配置：

```env
NFCAIME_CARD_WEBHOOK_URL=https://your-server.example.com/nfcaime/card-webhook
NFCAIME_CARD_WEBHOOK_TOKEN=your-secret-token
```

webhook 返回 JSON 时，会合并进客户端响应
