.PHONY: help secrets up up-cloudflare e2e e2e-keep publish-e2e publish-e2e-keep skill-smoke down

COMPOSE := docker compose -f docker-compose.cluster.yml
# Cloudflare Tunnel 模式：叠加 overlay（Caddy 改 :80 明文 + cloudflared）
COMPOSE_CF := docker compose -f docker-compose.cluster.yml -f docker-compose.cloudflare.yml

help: ## 显示帮助
	@grep -E '^[a-zA-Z0-9_-]+:.*?## .*$$' $(MAKEFILE_LIST) | sort | \
		awk 'BEGIN {FS = ":.*?## "}; {printf "  make %-14s - %s\n", $$1, $$2}'

secrets: ## 幂等生成 .env(CLUSTER_SECRET/IPFS_PUBLISH_TOKEN) 与 runtime/private/swarm.key(已存在则跳过)
	@[ -f .env ] || echo "CLUSTER_SECRET=$$(od -vN 32 -An -tx1 /dev/urandom | tr -d ' \n')" > .env
	@grep -q '^IPFS_PUBLISH_TOKEN=' .env 2>/dev/null || \
		echo "IPFS_PUBLISH_TOKEN=$$(od -vN 24 -An -tx1 /dev/urandom | tr -d ' \n')" >> .env
	@mkdir -p runtime/private
	@[ -f runtime/private/swarm.key ] || printf '/key/swarm/psk/1.0.0/\n/base16/\n%s\n' \
		"$$(od -vN 32 -An -tx1 /dev/urandom | tr -d ' \n')" > runtime/private/swarm.key
	@echo "secrets ready (.env + runtime/private/swarm.key)"

up: secrets ## 起单机 3 节点集群(直连模式；Caddy 本地 HTTP 或域名自动 TLS，见 docs §8)
	$(COMPOSE) up -d

up-cloudflare: secrets ## 起栈(Cloudflare Tunnel 模式)：Caddy 明文 :80 + cloudflared 出站隧道、零公网读端口；需 .env 的 CF_TUNNEL_TOKEN
	$(COMPOSE_CF) up -d

e2e: secrets ## 跑部署 e2e(集群成形/多副本/网关/容错；出 HTML 报告；跑完自动清理)
	./e2e/run-cluster.sh

e2e-keep: secrets ## 跑部署 e2e 并保留集群(便于继续手测)
	./e2e/run-cluster.sh --keep

publish-e2e: secrets ## 跑发布 e2e(写入口闸门/单文件/目录/过期；出 HTML 报告；跑完自动清理)
	./e2e/run-publish.sh

publish-e2e-keep: secrets ## 跑发布 e2e 并保留集群(便于继续手测)
	./e2e/run-publish.sh --keep

skill-smoke: up ## 按"第三方装好"的姿势独立验证发布 skill(仅注入 3 个 env，跑 skill 自带 test.sh)
	@IPFS_PUBLISH_ENDPOINT=http://127.0.0.1:9097 \
	 IPFS_PUBLISH_TOKEN=$$(grep '^IPFS_PUBLISH_TOKEN=' .env | cut -d= -f2) \
	 IPFS_BASE_URL=http://127.0.0.1:8088 \
	 ./skills/publish-artifact/test.sh

down: ## 停集群(两种模式都清；保留 runtime/ 数据)
	@CF_TUNNEL_TOKEN=$${CF_TUNNEL_TOKEN:-x} IPFS_PUBLISH_TOKEN=$${IPFS_PUBLISH_TOKEN:-x} $(COMPOSE_CF) down
