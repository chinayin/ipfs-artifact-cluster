---
name: gen-ssh-key
description: '按团队规范生成 SSH 密钥并返回公钥。Ed25519 默认、RSA 4096 兜底(禁用 RSA 2048),优先 puttygen(产 .ppk/.pem/.pub),未安装则降级 ssh-keygen(产私钥 + .pub)。文件名用服务名/用途作前缀,私钥 chmod 600。用于:"生成 ssh key"、"生成 ssh 公钥/私钥"、"新建一对密钥"、"generate ssh key"、"create ssh keypair"、"给 xxx 服务生成登录密钥"。生成的密钥默认存当前目录(或 .env 配置的目录),后续用途(导入平台 / 追加 authorized_keys)由使用者决定。'
---

# 生成 SSH 密钥(团队规范)

一条命令按团队规则产出符合规范的 SSH 密钥。纯 bash,依赖 puttygen 或 ssh-keygen。

## 团队规则(已固化进脚本)

- 密钥类型:默认 **Ed25519**;`--rsa` 用 **RSA 4096**;**永不生成 RSA 2048**。
- 生成工具:优先 **puttygen**(产 `.ppk/.pem/.pub`),未安装降级 **ssh-keygen**(产私钥 + `.pub`,无 `.ppk`)。
- 文件名:`<name>.ppk / .pem / .pub`,`<name>` = 服务名/用途。
- 备注 `-C`:默认 = `<name>`。
- 口令:默认无口令 + 强提醒;`--passphrase-file` 可加密。
- 覆盖:同名密钥默认拒绝,需 `--force`。
- 权限:私钥 `chmod 600`。

## 配置

输出目录优先级:`--out-dir` > 同目录 `.env` 的 `SSH_KEY_OUTPUT_DIR` > 当前目录。
首次可 `cp .env.example .env` 并改成集中目录(如 `~/.ssh/uhomes-keys`)。

## 用法

```bash
./gen-ssh-key.sh jumpserver                       # Ed25519 → jumpserver.{ppk,pem,pub}
./gen-ssh-key.sh jumpserver --rsa                 # RSA 4096
./gen-ssh-key.sh jumpserver --comment "lei.tian@uhomes.com"
./gen-ssh-key.sh jumpserver --passphrase-file ./pp.txt   # 加密私钥
./gen-ssh-key.sh jumpserver --out-dir ~/.ssh/uhomes-keys
./gen-ssh-key.sh jumpserver --force               # 覆盖同名
./gen-ssh-key.sh jumpserver --json                # 机器可读
./gen-ssh-key.sh jumpserver --dry-run             # 只看计划
./gen-ssh-key.sh --tool ssh-keygen jumpserver     # 强制不用 puttygen
```

## 产物

| 文件 | 用途 |
|------|------|
| `<name>.ppk` | PuTTY 原生密钥(仅 puttygen 路径) |
| `<name>.pem` | OpenSSH 私钥(chmod 600,勿外泄) |
| `<name>.pub` | OpenSSH 公钥(可复制导入 / 追加 authorized_keys) |

## 退出码

`0` 成功 · `1` 参数错误/目标已存在/生成失败 · `2` 无可用工具(puttygen 和 ssh-keygen 都没有)。

## 自测

```bash
bash test.sh
```
