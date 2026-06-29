# Agent 接入指南

本文档说明 AI Agent 如何将 HTML 文件上传到私有 IPFS Cluster，并获取可直接在浏览器渲染的访问链接。

---

## 服务端点

| 端点 | 说明 |
|------|------|
| `http://<host>:9095` | **Cluster IPFS 代理**，用于上传文件（接口同 Kubo `/api/v0/add`，但 pin 会在集群多副本）|
| `http://<host>:8080` | 网关，用于访问已上传内容 |

`<host>` 替换为节点宿主机的局域网 IP（如 `192.168.1.100`）或 `localhost`（本机访问）。

> **务必走 `:9095`（cluster 代理），不要直连某个 kubo 的 `:5001`**——直连 5001 上传的内容 cluster 不感知、不会复制。单节点模式同样走 `:9095`（只是暂只 1 份副本）。

---

## 上传契约

所有上传均通过以下接口完成：

```
POST http://<host>:9095/api/v0/add?cid-version=1&pin=true
Content-Type: multipart/form-data
```

**关键参数：**

| 参数 | 值 | 说明 |
|------|----|------|
| `cid-version` | `1` | 使用 CIDv1，Base32 编码，推荐格式 |
| `pin` | `true` | 固定内容，防止被 GC 清除 |

**响应格式**（每个文件一行 JSON）：

```json
{"Name":"index.html","Hash":"bafkreixxxxxx...","Size":"1234"}
```

关键字段：
- `Hash`：该文件或目录的 CID，用于构造访问 URL
- `Name`：文件名

目录上传时，**最后一行**为目录本身的 CID。

---

## 方式一：自包含单文件

**适用场景**：HTML 文件内联了所有 CSS / JS（无外链相对路径资源）。

### 上传

```bash
curl -fsS \
  -F "file=@/path/to/standalone.html" \
  "http://localhost:9095/api/v0/add?cid-version=1&pin=true"
```

**示例响应：**

```json
{"Name":"standalone.html","Hash":"bafkreiabcdef1234567890abcdef1234567890abcdef1234567890abcdef12","Size":"512"}
```

### 访问链接

```
http://localhost:8080/ipfs/bafkreiabcdef1234567890abcdef1234567890abcdef1234567890abcdef12
```

浏览器打开后直接渲染 HTML 页面。

### 脚本示例（提取 CID）

```bash
CID=$(curl -fsS \
  -F "file=@standalone.html" \
  "http://localhost:9095/api/v0/add?cid-version=1&pin=true" \
  | grep -o '"Hash":"[^"]*"' | sed 's/.*:"//;s/"//')

echo "访问链接: http://localhost:8080/ipfs/$CID"
```

---

## 方式二：目录 + 相对资源

**适用场景**：HTML 文件通过相对路径引用 CSS、JS、图片等（如 `<link href="./style.css">`）。必须将所有文件打包为一个目录一起上传。

### 目录结构示例

```
site/
├── index.html   （引用 ./style.css）
└── style.css
```

### 上传

```bash
curl -fsS \
  -F "file=@site/index.html;filename=index.html" \
  -F "file=@site/style.css;filename=style.css" \
  "http://localhost:9095/api/v0/add?wrap-with-directory=true&cid-version=1&pin=true"
```

**关键参数：**

| 参数 | 值 | 说明 |
|------|----|------|
| `wrap-with-directory` | `true` | 将多文件包装为一个 IPFS 目录 |
| `filename=...` | 文件名 | 指定文件在目录中的路径名，必须与 HTML 内的相对路径对应 |

**示例响应**（多行，最后一行为目录 CID）：

```json
{"Name":"index.html","Hash":"bafkreifile1xxxxxxx","Size":"256"}
{"Name":"style.css","Hash":"bafkreifile2xxxxxxx","Size":"64"}
{"Name":"","Hash":"bafybeidirsxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx","Size":"512"}
```

### 访问链接

```
http://localhost:8080/ipfs/bafybeidirsxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx/index.html
```

- 目录 CID 后面须加 `/index.html` 指向入口文件
- 页面加载时，浏览器自动通过同一路径前缀加载 `style.css`，相对路径解析正确

### 脚本示例（提取目录 CID）

```bash
DIR_CID=$(curl -fsS \
  -F "file=@site/index.html;filename=index.html" \
  -F "file=@site/style.css;filename=style.css" \
  "http://localhost:9095/api/v0/add?wrap-with-directory=true&cid-version=1&pin=true" \
  | grep -o '"Hash":"[^"]*"' | tail -1 | sed 's/.*:"//;s/"//')

echo "访问链接: http://localhost:8080/ipfs/$DIR_CID/index.html"
```

---

## 何时用哪种方式

| 情况 | 选择 |
|------|------|
| HTML 内联所有样式和脚本（`<style>` / `<script>` 标签） | **方式一**：单文件，简单直接 |
| HTML 通过相对路径引用外部 CSS / JS / 图片 | **方式二**：目录方式，保留相对路径关系 |
| 多页面站点（有多个 HTML 相互链接） | **方式二**：整个站目录一起上传 |

---

## 渲染说明

- Kubo 网关确定 `Content-Type` 的方式：路径中带文件名/扩展名时（如 `/ipfs/<CID>/index.html`）按扩展名定 MIME；直接访问无扩展名的内容时（如 `/ipfs/<CID>`）回退到内容嗅探。常见类型：
  - `.html` / 嗅探为 HTML → `text/html; charset=utf-8`
  - `.css` → `text/css; charset=utf-8`
  - `.js` → `text/javascript` 或 `application/javascript`（随 Kubo 版本而异，仅供参考）
- 浏览器收到 `text/html` 后直接渲染，无需额外配置。
- 相对路径资源（CSS、图片等）必须使用**方式二（目录）**上传，否则网关无法按路径解析到对应文件。

---

## localhost 访问说明

本项目已关闭 `localhost` 的子域名重定向（详见 `scripts/init-cluster.d/001-config.sh` 中的 `Gateway.PublicGateways` 配置），因此：

- `curl http://localhost:8080/ipfs/<CID>` 直接返回内容，**无需** `-L` 跟随重定向
- `http://localhost:8080/ipfs/<CID>` 在浏览器中直接渲染，不会跳转到子域名 URL

使用**局域网 IP**（如 `http://192.168.x.x:8080/ipfs/<CID>`）访问时，同样直接返回内容，行为一致。

**自定义域名**（如 `http://files.example.com:8080/ipfs/<CID>`）访问时：由于 `Gateway.PublicGateways` 配置只匹配 `Host: localhost`，其它域名走 Kubo 默认 path 网关，直接返回内容、不做子域名重定向——这正是后续公网/域名部署要使用的访问形态。若将来需要为某个域名启用子域名隔离（更安全的 origin 隔离），可在 `Gateway.PublicGateways` 下为该域名新增一项配置，不影响现有 `localhost` 行为。

---

## 完整 Agent 调用伪代码（Python）

```python
import subprocess
import json

def upload_html(host: str, html_path: str) -> str:
    """上传单文件 HTML，返回访问 URL"""
    result = subprocess.run([
        "curl", "-fsS",
        "-F", f"file=@{html_path}",
        f"http://{host}:9095/api/v0/add?cid-version=1&pin=true"
    ], capture_output=True, text=True, check=True)

    # 最后一行 JSON 里取 Hash
    last_line = result.stdout.strip().splitlines()[-1]
    cid = json.loads(last_line)["Hash"]
    return f"http://{host}:8080/ipfs/{cid}"


def upload_site(host: str, files: dict) -> str:
    """上传目录，files = {filename: local_path}，返回 index.html 访问 URL"""
    args = ["curl", "-fsS"]
    for filename, path in files.items():
        args += ["-F", f"file=@{path};filename={filename}"]
    args.append(
        f"http://{host}:9095/api/v0/add?wrap-with-directory=true&cid-version=1&pin=true"
    )

    result = subprocess.run(args, capture_output=True, text=True, check=True)
    last_line = result.stdout.strip().splitlines()[-1]
    dir_cid = json.loads(last_line)["Hash"]
    return f"http://{host}:8080/ipfs/{dir_cid}/index.html"
```
