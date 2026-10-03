# Anywhere 互通协议 (Protocol v1)

手机端（Flutter）与电脑端（Anywhere Desktop）都通过 **公网中继服务器** 通信。
本文件是中继服务器、Android 端、桌面端三方的契约，任何一方改动都必须同步。

## 1. 传输层

| 用途 | 协议 | 地址 |
| --- | --- | --- |
| 实时消息 | WebSocket | `ws://<host>:<port>/ws` （生产建议 `wss://`）|
| 文件上传 | HTTP POST | `http://<host>:<port>/upload?token=..&name=..` （裸字节流 body）|
| 文件下载 | HTTP GET | `http://<host>:<port>/file/<fileId>?token=..` |
| 健康检查 | HTTP GET | `http://<host>:<port>/health` |

## 2. 连接与鉴权

连接 URL 查询参数：

```
ws://host:port/ws
  ?token=<共享令牌>
  &deviceId=<设备唯一ID>
  &deviceName=<可读名称>
  &platform=android|desktop
```

- `token` 必须在服务器的 `AUTH_TOKENS`（`userId:token` 列表）中，否则连接被拒绝（close code `4001`）。
- 同一 `userId` 下的所有设备互为"同账号设备"，可以互相收发消息。
- 服务器为每个 `deviceId` 只保留一条连接，新连接会顶掉旧连接（close code `4000`）。

## 3. 消息信封 (Envelope)

所有 WebSocket 帧都是 JSON：

```json
{
  "v": 1,
  "type": "chat",
  "id": "uuid",
  "from": "deviceId",
  "to": "*",
  "ts": 1730000000000,
  "payload": { }
}
```

| 字段 | 说明 |
| --- | --- |
| `v` | 协议版本，当前为 `1` |
| `type` | 消息类型，见下表 |
| `id` | 消息唯一 ID（uuid v4），用于 ack / 去重 |
| `from` | 发送方 deviceId（服务器会以真实连接覆盖）|
| `to` | 目标：`*`=同账号其他设备；`<deviceId>`=指定设备；`<userId>`=某用户全部设备 |
| `ts` | 毫秒时间戳 |
| `payload` | 类型相关负载 |

## 4. 消息类型

| type | 方向 | payload | 说明 |
| --- | --- | --- | --- |
| `welcome` | S→C | `{userId, deviceId, serverTime}` | 连接成功回执 |
| `presence` | C↔S | `{devices:[{deviceId,deviceName,platform,connectedAt,online}]}` | 在线设备列表；加入/离开时服务端主动广播 |
| `chat` | C→C | `{role, text, conversationId?, attachments?[]}` | 聊天消息，`role` ∈ user/assistant/system |
| `notification` | C→C | `{title, body}` | 通知推送（如定时任务完成）|
| `file_share` | C→C | `{file:{id,name,size,mime,createdAt}}` | 分享已上传文件的元信息 |
| `file_stored` | S→C | `{id,name,size,mime,createdAt}` | 服务端对 `file_chunk_upload` 的回执 |
| `file_chunk_upload` | C→S | `{name,mime,data(base64)}` | 小文件通过 WS 上传（大文件用 HTTP `/upload`）|
| `ping` / `pong` | C↔S | `-` | 心跳，客户端每 15s 发一次 |
| `delivery_status` | S→C | `{status:"undelivered", to}` | 目标不在线时通知发送方 |
| `error` | S→C | `{code, message}` | 错误 |

## 5. 典型时序

### 5.1 手机发消息给电脑
```
Android: {type:"chat", to:"desktop-xxx", payload:{role:"user", text:"你好"}}
Server  -> 桌面端
```

### 5.2 电脑端定时任务完成后推送通知
```
Desktop: {type:"notification", to:"*", payload:{title:"日报完成", body:"已生成今日日报"}}
Server  -> 手机端（本地通知弹出）
```

### 5.3 文件互传（推荐路径）
```
发送方: POST /upload (裸字节)  ->  {ok:true, file:{id, name, size, mime}}
发送方: {type:"file_share", to:"*", payload:{file:{...}}}
接收方: GET /file/<id>?token=... 下载到本地
```

## 6. 兼容性约定

- 任何一端收到未知 `type` 必须**忽略**，不得断开连接。
- `v` 不一致时，接收方可忽略或提示升级；服务端当前不校验 `v`。
- `payload` 中新增字段属于向后兼容；删除/改义字段需要提升 `v`。
