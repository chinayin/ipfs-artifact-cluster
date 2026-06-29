# Kubo (IPFS) 私有化 HTML 托管 POC — 设计文档

- 日期：2026-06-24
- 状态：待评审
- 方案：**B（纯 Kubo，Agent 直连 API）**

## 1. 背景与目标

Agent 会生成大量 HTML 附件，需要把这些附件托管起来，并通过 **IP / 域名** 远程访问（浏览器能直接渲染）。本 POC 用 [Kubo（IPFS）](https://github.com/ipfs/kubo) 私有化部署来满足这一需求。

**本期目标（POC）**：在本地 / 局域网用 Docker Compose 跑通一个**单节点离线** Kubo，验证：

1. Agent 能通过 Kubo 原生 API（`/api/v0/add`）上传 HTML，拿到内容寻址链接。
2. 上传的 HTML 能通过网关在浏览器中**正确渲染**（而非被当作文件下载）。
3. 有一套**一键 e2e 测试脚本**验证整条链路。

## 2. 范围与非目标

**范围内**：
- 单台机器 / 局域网部署，单个 Kubo 节点，**离线模式**（不连公网 IPFS 网络，数据不外泄）。
- Agent **直连 Kubo API**（方案 B），尽量使用 Kubo 原生能力，不写自定义后端服务。
- 访问链接形态：网关路径 `http://<host>:8080/ipfs/<CID>`。
- 一键 e2e（bash + curl）。

**非目标（本期不做，留待后续）**：
- 友好短链 / 固定路径映射（需有状态服务，见 §9 演进）。
- 公网部署、域名、TLS、反向代理、鉴权加固。
- 多节点 / 私有 swarm 集群。

## 3. 架构

```
                 ┌─────────────────────────── Kubo 容器 (ipfs/kubo) ───────────────────────────┐
 Agent ─── POST /api/v0/add ───▶  API :5001 (离线，POC 局域网裸奔)                               │
                                 │                                                              │
 浏览器/用户 ── GET /ipfs/<CID> ─▶  Gateway :8080  ── 嗅探 Content-Type ──▶ 渲染 HTML            │
                                 │                                                              │
                                 └── 本地块存储（卷 /data/ipfs，重启不丢）                       │
                 └──────────────────────────────────────────────────────────────────────────┘
```

- **单节点离线**：daemon 以 `--offline` 运行，并清空 bootstrap、`Routing.Type=none`，不主动连接公网。本地 `add` / `cat` / 网关读取均正常工作。
- 端口：`5001`（API，供 Agent 上传）、`8080`（Gateway，供用户读取）。`4001`（swarm）离线不需要，不映射。
- 持久化：卷挂载 `/data/ipfs`。

## 4. 组件与配置

### 4.1 docker-compose.yml（草案）

```yaml
services:
  ipfs:
    image: ipfs/kubo:v0.42.0          # 锁定版本，保证可复现
    container_name: kubo-poc
    command: ["daemon", "--migrate=true", "--offline", "--agent-version-suffix=docker"]
    ports:
      - "5001:5001"                   # API → 0.0.0.0，局域网可达（POC 裸奔）
      - "8080:8080"                   # Gateway → 0.0.0.0，局域网可达
    volumes:
      - ./data/ipfs:/data/ipfs        # 仓库持久化
      - ./init.d:/container-init.d:ro # 启动前配置脚本
    restart: unless-stopped
```

> 说明：官方示例把端口绑到 `127.0.0.1` 是出于安全。POC 需要局域网其他机器访问，这里绑 `0.0.0.0`（即 `5001:5001`）。**生产务必收紧**（见 §8）。

### 4.2 init.d/001-config.sh（草案）

`/container-init.d/*.sh` 在 `ipfs init` 之后、daemon 启动之前按字典序执行，是配置的官方入口：

```sh
#!/bin/sh
set -ex

# 监听所有接口（配合 docker 端口映射对局域网暴露）
ipfs config Addresses.API     /ip4/0.0.0.0/tcp/5001
ipfs config Addresses.Gateway /ip4/0.0.0.0/tcp/8080

# CORS：允许 Agent 从任意来源调用 API（POC 放开）
ipfs config --json API.HTTPHeaders.Access-Control-Allow-Origin  '["*"]'
ipfs config --json API.HTTPHeaders.Access-Control-Allow-Methods '["PUT","POST","GET"]'

# 离线单节点：关闭路由、清空 bootstrap（与 --offline 双保险，且持久化到配置）
ipfs config Routing.Type none
ipfs bootstrap rm --all

# 保证网关返回可渲染内容（反序列化响应）
ipfs config --json Gateway.DeserializedResponses true
```

## 5. Agent 上传契约（直连 API）

### 5.1 自包含单文件 HTML（内联 CSS/JS）

```bash
curl -s -F file=@page.html "http://<host>:5001/api/v0/add?cid-version=1&pin=true"
# 返回：{"Name":"page.html","Hash":"bafy...","Size":"..."}
# 访问：http://<host>:8080/ipfs/bafy...
```

### 5.2 带相对资源的 HTML（外链 ./style.css、./app.js、图片）

单文件 add 会导致相对路径失效，必须按**目录**添加，使相对路径在同一目录 CID 下解析：

```bash
curl -s \
  -F "file=@site/index.html;filename=site/index.html" \
  -F "file=@site/style.css;filename=site/style.css" \
  "http://<host>:5001/api/v0/add?wrap-with-directory=true&cid-version=1&pin=true"
# 返回多行 JSON，最后一行是目录 CID
# 访问：http://<host>:8080/ipfs/<目录CID>/index.html
```

> 文档将给出两种封装示例（单文件 / 目录），并说明何时该用哪种。

## 6. HTML 渲染说明（核心验证点）

- 网关通过路径访问单个 HTML 文件时，Kubo 用内容嗅探返回 `Content-Type: text/html; charset=utf-8`，浏览器**直接渲染**。
- 带相对资源时，必须用目录 CID + `index.html` 路径，相对引用才能解析到同目录下的其他文件。
- 已知约束：path 网关下不同 CID 共享同一 origin（POC 可接受）；生产建议用 subdomain 网关隔离 origin 以防 XSS（见 §9）。
- 局域网用 LAN IP 访问网关（`http://<LAN-IP>:8080/ipfs/<CID>`）属 path 网关，默认对任意 Host 工作；**e2e 会实测确认**。
- **实测补充（实现阶段发现）**：Kubo v0.42.0 默认对 `localhost` 的 path 风格 URL 做 HTTP 301 重定向到子域名网关（`<CID>.ipfs.localhost:8080`），导致命令行 `curl`（不带 `-L`）拿不到内容。本项目在 `init.d/001-config.sh` 中通过 `Gateway.PublicGateways` 把 `localhost` 的 `UseSubdomains` 设为 `false` 关闭该重定向。此配置仅匹配 `Host: localhost`，**不影响 LAN IP 与自定义域名**（它们走默认 path 网关直接返回，正是远程访问要用的形态）。
- **实测补充**：Kubo 官方镜像在每次容器启动时都会执行 `/container-init.d/` 脚本（不止首次 `ipfs init`），故修改 `init.d/001-config.sh` 后 `docker compose restart` 即可让新配置生效；脚本须保持幂等。
- **实测修正（WebUI 与 `--offline`）**：原设计 daemon 用 `--offline`，但实测发现这会完全禁用网络栈，使 WebUI 依赖的 `stats/bw`、`swarm/peers` 报错（`must be run in online mode`），WebUI 判定「无法连接 RPC」。最终**去掉 `--offline`**，改为网络栈在线 + `Routing.Type=none` + 空 bootstrap + 不映射 4001 端口实现等价隔离（实测连接 peer 数恒为 0），既保证不连公网、数据不外泄，又让 WebUI 可用。WebUI 资源通过首次启动的一次性联网引导拉取并 pin（见 `init.d/001-config.sh`）。

## 7. e2e 测试流程（bash + curl，一键）

脚本 `e2e/run.sh`，退出码非 0 即失败，步骤：

1. `docker compose up -d` 启动 Kubo。
2. 轮询 `POST http://localhost:5001/api/v0/version` 直到就绪（带超时）。
3. **Case 1 — 自包含 HTML 渲染**：
   - 生成内联样式的 `fixtures/standalone.html`。
   - `add` 拿 CID → `curl -I http://localhost:8080/ipfs/<CID>` 断言 `200` 且 `Content-Type` 含 `text/html`。
   - `curl` 取正文，断言包含预置标记字符串。
4. **Case 2 — 目录 + 相对资源**：
   - 生成 `fixtures/site/`（`index.html` 引用 `./style.css`）。
   - 目录 add 拿目录 CID → 访问 `/<CID>/index.html` 断言 `200 text/html`；访问 `/<CID>/style.css` 断言 `200 text/css`。
5. **Case 3 — 局域网访问**：探测本机 LAN IP，用它替换 localhost 重跑 Case 1 的网关断言（探测不到 IP 则 SKIP 并提示）。
6. 打印 `PASS/FAIL` 汇总；`--keep` 可保留容器，默认 `docker compose down` 清理。

## 8. 安全说明

- **POC 局域网裸奔**：5001 API 无鉴权、CORS 全开，仅限可信局域网。
- **红线**：5001 **绝不可**暴露到公网（等同把节点完全交出）。文档以醒目方式标注。
- 离线模式 + 清空 bootstrap 确保数据不进入公共 IPFS 网络。

## 9. 后续演进（非本期）

- 友好短链：加一个极薄映射服务（短码 → CID）或 nginx 重写。
- 公网访问：反向代理 + 域名 + TLS，网关用 subdomain 模式隔离 origin。
- API 加固：限制 CORS 来源、网络隔离、只让上传方可达 5001。

## 10. 交付物 / 目录结构

```
.
├── docker-compose.yml
├── init.d/
│   └── 001-config.sh
├── e2e/
│   ├── run.sh
│   └── fixtures/            # 测试脚本运行时生成或预置
├── data/ipfs/              # 运行时生成（卷），加入 .gitignore
└── docs/
    ├── 部署文档（deploy）：compose、配置、启动、停止
    ├── Agent 接入文档（upload）：两种上传方式 + 链接形态
    └── e2e 测试文档：如何运行、各 case 含义、排错
```

## 11. 验收标准

- [ ] `docker compose up -d` 一键拉起离线 Kubo。
- [ ] Agent 通过 `/api/v0/add` 上传 HTML 拿到 CID。
- [ ] 浏览器访问网关链接，自包含 HTML **正确渲染**。
- [ ] 带相对资源的目录 HTML，主页与子资源均可访问、类型正确。
- [ ] `e2e/run.sh` 一键跑通，全部 case PASS。
- [ ] docs/ 下三份文档齐全，可照着复现。
