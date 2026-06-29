#!/bin/sh
set -ex
# Cluster-node kubo config (runs every start, idempotent). Shared by the single-host
# trial and multi-host (ECS/EC2). See docs/SINGLE_HOST_DEPLOYMENT.md and docs/MULTI_HOST_DEPLOYMENT.md.
#
# Isolation: /data/ipfs/swarm.key private network — only talks to peers sharing the key.
# Discovery (no public DHT on a private net), in priority order:
#   1) IPFS_SEED_ADDR set (multi-host) -> bootstrap to that full multiaddr
#   2) IS_SEED=true (multi-host seed)  -> bootstrap to nobody (this node is the anchor)
#   3) otherwise single-host: SELF != SEED -> discover seed PeerID via its API over docker net

SELF=${IPFS_SELF:-ipfs0}
SEED=${IPFS_SEED:-ipfs0}          # single-host seed service name

ipfs config Addresses.API     /ip4/0.0.0.0/tcp/5001
ipfs config Addresses.Gateway /ip4/0.0.0.0/tcp/8080

# CORS open for Agent / cluster proxy (POC only).
ipfs config --json API.HTTPHeaders.Access-Control-Allow-Origin  '["*"]'
ipfs config --json API.HTTPHeaders.Access-Control-Allow-Methods '["PUT","POST","GET"]'

# Serve renderable content + disable localhost subdomain 301 redirect (same as v1).
ipfs config --json Gateway.DeserializedResponses true
ipfs config --json Gateway.PublicGateways '{"localhost":{"Paths":["/ipfs","/ipns","/api"],"UseSubdomains":false}}'

# Private network isolation + private DHT routing.
ipfs bootstrap rm --all
ipfs config Routing.Type dht
# Private networks must disable AutoConf: Kubo v0.42 refuses the default mainnet
# autoconf URL once swarm.key is detected (daemon would crash on startup otherwise).
ipfs config --json AutoConf.Enabled false

# Multi-host: announce the externally reachable address so peers don't dial the
# container-internal IP (the #1 cause of multi-host connection failures).
if [ -n "${ANNOUNCE_IP:-}" ]; then
  ipfs config --json Addresses.Announce \
    "[\"/ip4/$ANNOUNCE_IP/tcp/4001\",\"/ip4/$ANNOUNCE_IP/udp/4001/quic-v1\"]"
fi

# Establish bootstrap (one of three modes).
if [ -n "${IPFS_SEED_ADDR:-}" ]; then
  ipfs bootstrap add "$IPFS_SEED_ADDR"
  echo ">>> registered seed bootstrap (multi-host): $IPFS_SEED_ADDR"
elif [ "${IS_SEED:-}" = "true" ]; then
  echo ">>> this node is the seed (multi-host), no bootstrap registered."
elif [ "$SELF" != "$SEED" ]; then
  SEED_ID=""
  for i in $(seq 1 60); do
    SEED_ID=$(ipfs --api="/dns4/$SEED/tcp/5001" id -f='<id>' 2>/dev/null) || true
    [ -n "$SEED_ID" ] && break
    sleep 2
  done
  if [ -n "$SEED_ID" ]; then
    ipfs bootstrap add "/dns4/$SEED/tcp/4001/p2p/$SEED_ID"
    echo ">>> registered seed bootstrap (single-host): $SEED ($SEED_ID)"
  else
    echo ">>> WARN: seed $SEED not ready, no bootstrap registered (replication may suffer)."
  fi
fi
