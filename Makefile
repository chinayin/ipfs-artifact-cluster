.PHONY: help claude-skills secrets up e2e e2e-keep down

COMPOSE := docker compose -f docker-compose.cluster.yml

help: ## 显示帮助
	@grep -E '^[a-zA-Z0-9_-]+:.*?## .*$$' $(MAKEFILE_LIST) | sort | \
		awk 'BEGIN {FS = ":.*?## "}; {printf "  make %-14s - %s\n", $$1, $$2}'

claude-skills: ## 把顶层 skills/ 幂等软链进被忽略的 .claude/skills/(clone 后跑一次)
	@mkdir -p .claude/skills
	@for d in skills/*/; do \
		name=$$(basename "$$d"); \
		ln -sfn ../../skills/$$name .claude/skills/$$name; \
		echo "linked .claude/skills/$$name -> ../../skills/$$name"; \
	done

secrets: ## 幂等生成 .env(CLUSTER_SECRET/IPFS_PUBLISH_TOKEN) 与 runtime/private/swarm.key(已存在则跳过)
	@[ -f .env ] || echo "CLUSTER_SECRET=$$(od -vN 32 -An -tx1 /dev/urandom | tr -d ' \n')" > .env
	@grep -q '^IPFS_PUBLISH_TOKEN=' .env 2>/dev/null || \
		echo "IPFS_PUBLISH_TOKEN=$$(od -vN 24 -An -tx1 /dev/urandom | tr -d ' \n')" >> .env
	@mkdir -p runtime/private
	@[ -f runtime/private/swarm.key ] || printf '/key/swarm/psk/1.0.0/\n/base16/\n%s\n' \
		"$$(od -vN 32 -An -tx1 /dev/urandom | tr -d ' \n')" > runtime/private/swarm.key
	@echo "secrets ready (.env + runtime/private/swarm.key)"

up: secrets ## 起单机 3 节点集群(含 Caddy 反代)
	$(COMPOSE) up -d

e2e: secrets ## 跑集群 e2e(跑完自动清理)
	./e2e/run-cluster.sh

e2e-keep: secrets ## 跑集群 e2e 并保留集群(便于继续手测)
	./e2e/run-cluster.sh --keep

down: ## 停集群(保留 runtime/ 数据)
	$(COMPOSE) down
