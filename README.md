<p align="center">
  <img src="./iOS_APP/iOS_APP/Assets.xcassets/AppIcon.appiconset/icon-1024.png" width="104" alt="NFCAiME">
</p>

<h1 align="center">NFCAiME</h1>

<p align="center">开源客户端壳、服务器接口与自部署基础实现</p>

<p align="center">
  <a href="https://github.com/Project-HashCat/NFCAiME/releases/latest"><strong>下载 Release 版</strong></a>
</p>

> <strong>出于公开发布和项目边界考虑，本仓库不会内置任何有关与官方服务器通讯的内容与计算逻辑</strong>

## 仓库说明

本仓库是 NFCAiME 的公开版本，用于展示客户端结构、自定义服务器配置流程、RSA 加密上传接口和最小服务端接收逻辑。

公开源码与发布安装包的边界如下：

- 公开源码保留 UI、NFC 读取流程、自定义服务器列表、RSA 上传、错误日志和服务端 webhook 扩展点
- 公开源码不包含官方服务器通讯、卡号计算、Access Code 解密或 Bot 绑定等核心逻辑
- Release 中的 IPA/APK 永远由私人仓库构建后发布到本仓库 Release，不从本仓库源码直接构建

## 目录结构

```text
Android-APP/  Android 客户端公开源码
iOS_APP/      iOS 客户端公开源码
server/       自部署服务端公开源码
```

## 客户端

iOS 和 Android 公开源码提供同一类能力：

- 本地读取卡片基础信息
- 用户自行添加远端服务器 URL 和 RSA 公钥
- 远端模式下上传加密后的卡片安全数据和认证块
- 显示服务器返回的 Access Code、Konami Card Number、Private Network 等字段
- 保存卡片记录、隐私显示、错误日志上传和 Release 跳转

客户端不会内置默认公开服务器地址。需要远端功能时，请在 App 内添加自己的服务器地址和该服务器提供的 RSA 公钥。

## 服务端快速开始

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

启动后检查：

```bash
curl http://127.0.0.1:8000/health
curl http://127.0.0.1:8000/public-key
```

客户端服务器地址填写 `/card` 入口，例如：

```text
https://example.com/aime_reader/card
```

同级路径需要能访问：

```text
/public-key
/debug-log
/health
```

## Webhook 扩展

如果你要实现账号系统、Bot 绑定、私服联动或其他自定义功能，把 webhook 配到服务端：

```env
NFCAIME_CARD_WEBHOOK_URL=https://your-server.example.com/nfcaime/card-webhook
NFCAIME_CARD_WEBHOOK_TOKEN=your-secret-token
```

服务端会将解密后的读卡记录转发给 webhook。webhook 返回 JSON 时，会合并进客户端响应。

示例响应：

```json
{
  "ok": true,
  "code": "YOUR-CARD-CODE",
  "accessCodeHex": "50110000000000000000",
  "konamiCardNumber": "ABCD1234EFGH5678",
  "privateNetworkNumber": "00080000000000000000"
}
```

## API

### GET /health

健康检查。

### GET /public-key

返回 RSA 公钥 PEM，客户端会使用它加密卡片安全数据。

### POST /card

接收客户端上传的读卡数据。服务端只接受加密字段：

```json
{
  "spad0Encrypted": "base64..."
}
```

### POST /debug-log

接收客户端手动上传的加密错误日志。

## 注意事项

- 私钥只放在服务器，不要提交到 Git
- 客户端只保存服务器 URL 和公钥
- 自定义业务逻辑建议通过 webhook 或独立后端实现
- 生产环境建议只通过 HTTPS 暴露服务
