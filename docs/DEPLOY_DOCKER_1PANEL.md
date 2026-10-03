# 1Panel / Docker 部署指南

本项目的中继服务器（`server/`）已经容器化，**推荐在 1Panel 上用 Docker Compose 一键部署**。

---

## 方案一：1Panel 图形界面（推荐，最省事）

### 1. 上传代码

在 1Panel → **文件** 里，把本仓库的 `server/` 目录上传到服务器，例如：

```
/opt/1panel/apps/anywhere-relay/
├── Dockerfile
├── docker-compose.yml
├── package.json
├── env.docker.example
└── src/
```

> 也可以只上传这些文件；`data/` 会自动生成。

### 2. 创建环境变量文件

把 `env.docker.example` 复制成 `.env`，改成你自己的令牌：

```ini
PORT=8787
AUTH_TOKENS=default-user:你的强随机令牌
FILE_TTL_HOURS=72
MAX_FILE_MB=512
```

> 🔑 `AUTH_TOKENS` 格式是 `用户ID:令牌`。手机端和电脑端都用这个「令牌」连接，「用户ID」用于区分不同的人。
> 生成随机令牌示例：`openssl rand -hex 16`。

### 3. 用 1Panel 创建 Compose 应用

1Panel → **容器** → **编排** → **创建编排**
- **名称**：`anywhere-relay`
- **来源**：选「从文件」或直接粘贴 `docker-compose.yml` 内容
- 确认 `.env` 与环境变量
- 点 **确定/部署**

1Panel 会自动执行 `docker compose up -d --build`。

### 4. 放行端口

1Panel → **防火墙** → 放行 `8787`（TCP）。
若服务器有云厂商安全组（阿里云/腾讯云），也要在控制台放行该端口。

### 5. 验证

浏览器或服务器上访问：

```
http://你的服务器IP:8787/health
```

返回下面即成功：
```json
{"ok":true,"service":"anywhere-relay","version":1}
```

---

## 方案二：SSH 命令行（同样简单）

```bash
cd /opt/anywhere-mobile/server
cp env.docker.example .env
# 编辑 .env 填写 AUTH_TOKENS
docker compose up -d --build
docker compose logs -f          # 查看日志
```

---

## 手机 / 电脑端连接地址

部署成功后，两端都填：

| 配置项 | 值 |
| --- | --- |
| 中继服务器地址 | `ws://你的服务器IP:8787/ws` |
| 访问令牌 | 与 `.env` 的 `AUTH_TOKENS` 中令牌一致 |
| 用户 ID | 与 `.env` 里 `AUTH_TOKENS` 的用户ID一致（如 `default-user`）|

---

## 🔒 强烈建议：启用 HTTPS / WSS

`ws://` 是明文传输，令牌和数据会被监听。生产环境请用 1Panel 的**网站反向代理 + Let's Encrypt 证书**：

1. 1Panel → **网站** → 创建网站，域名如 `relay.example.com`
2. 申请 SSL 证书（Let's Encrypt，一键签发）
3. 添加**反向代理**，指向本机 `127.0.0.1:8787`
   - 关键：反代需支持 **WebSocket**（1Panel 默认会带 `Upgrade`/`Connection` 头；若无，手动补上）
4. 开启 **HTTPS 强制跳转**

之后两端地址改为：

```
wss://relay.example.com/ws
```

反向代理需要的关键 Nginx 片段：

```nginx
location / {
    proxy_pass http://127.0.0.1:8787;
    proxy_http_version 1.1;
    proxy_set_header Upgrade $http_upgrade;
    proxy_set_header Connection "upgrade";
    proxy_set_header Host $host;
    proxy_set_header X-Real-IP $remote_addr;
    proxy_read_timeout 3600s;   # 长连接，别让网关掐断
}
```

---

## 常用运维命令

```bash
docker compose ps                 # 状态
docker compose logs -f            # 日志
docker compose restart            # 重启
docker compose down               # 停止并删除容器（./data 里的文件保留）
docker compose up -d --build      # 改代码后重新构建
```

## 数据与持久化

- 中转文件保存在宿主机 `./data/files/`（容器内 `/app/data/files`）
- 超过 `FILE_TTL_HOURS` 的文件会被自动清理
- 删除容器不会丢失 `./data`；除非手动删目录

## 常见问题

| 现象 | 排查 |
| --- | --- |
| 手机连不上 | 防火墙/安全组是否放行端口；地址是否用 `ws://` 而非 `http://`；令牌是否一致 |
| 电脑端在线但手机看不到 | 两端 `userId` 必须相同；`AUTH_TOKENS` 里是否包含该 userId |
| WSS 握手失败 | 反代是否开启 WebSocket 支持；`proxy_read_timeout` 是否够大 |
| 上传大文件失败 | 调大 `MAX_FILE_MB`，并检查反代 `client_max_body_size` |
| 容器起不来 | `docker compose logs` 看报错；多半是 `.env` 的 `AUTH_TOKENS` 为空 |
