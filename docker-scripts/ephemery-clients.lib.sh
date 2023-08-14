#!/bin/bash

# ~base dir
base_datadir="/data"

# ephemery config
testnet_repository="ephemery-testnet/ephemery-genesis"
testnet_configdir="~base/ephemery-config"

# external ip
extip=""

# Ports
port_el_p2p=30303
port_el_http_rpc_addr=172.17.0.1
port_el_http_rpc=8545
port_el_engine_addr=172.17.0.1
port_el_engine=8551

port_cl_p2p=9000
port_cl_http_rpc_addr=172.17.0.1
port_cl_http_rpc=5052

# engine auth jwt
engine_auth_jwt="~base/jwtsecret"

# execution endpoint
execution_url="http://172.17.0.1:${port_el_engine}"

# selected client
selected_el_client="geth"
selected_cl_client="lighthouse"

# helper functions

resolve_path() {
  local dpath=$1
  if [ "${dpath:0:6}" == "~base/" ]; then
    dpath="${base_datadir}/${dpath:6}"
  fi
  echo $dpath
}

ensure_jwtsecret() {
  # create jwtsecret if not found
  if ! [ -f $1 ]; then
    echo -n 0x$(openssl rand -hex 32 | tr -d "\n") > $1
  fi
}

ensure_extip() {
  if [ "$extip" == "" ]; then
    extip=$(curl -s http://whatismyip.akamai.com/)
  fi
}

get_github_release() {
  curl --silent "https://api.github.com/repos/$1/releases/latest" |
    grep '"tag_name":' |
    sed -E 's/.*"([^"]+)".*/\1/' |
    head -n 1
}

download_testnet_genesis() {
  local genesis_release=$1
  local testnet_dir=$(resolve_path "$testnet_configdir")

  # remove old genesis
  if [ -d $testnet_dir ]; then
    rm -rf $testnet_dir/*
  else
    mkdir -p $testnet_dir
  fi

  # get latest genesis
  wget -qO- https://github.com/$testnet_repository/releases/download/$genesis_release/testnet-all.tar.gz | tar xz -C $testnet_dir
}

# main function
ephemery_node_main() {
  case "$1" in
  retention)
    retention_main
    ;;
  load-genesis)
    download_testnet_genesis $(get_github_release $testnet_repository)
    ;;
  start)
    call_client_fn $selected_el_client "start"
    call_client_fn $selected_cl_client "start"
    ;;
  start-el)
    call_client_fn $selected_el_client "start"
    ;;
  start-cl)
    call_client_fn $selected_cl_client "start"
    ;;
  stop)
    call_client_fn $selected_el_client "stop"
    call_client_fn $selected_cl_client "stop"
    ;;
  stop-el)
    call_client_fn $selected_el_client "stop"
    ;;
  stop-cl)
    call_client_fn $selected_cl_client "stop"
    ;;
  *)
    echo "unknown action. supported actions: retention, load-genesis, start, start-el, start-cl, stop, stop-el, stop-cl"
    ;;
  esac
}

# retention logic

retention_main() {
  local testnet_dir=$(resolve_path "$testnet_configdir")
  if [ ! -f $testnet_dir/genesis.json ] | [ ! -f $testnet_dir/retention.vars ]; then
    retention_reset $(get_github_release $testnet_repository)
  else
    retention_check
  fi
}

retention_check() {
  local testnet_dir=$(resolve_path "$testnet_configdir")
  local current_time=$(date +%s)
  local testnet_timeout genesis_release

  source $testnet_dir/retention.vars

  testnet_timeout=$(expr $GENESIS_TIMESTAMP + $GENESIS_RESET_INTERVAL - 300)
  echo "genesis timeout: $(expr $testnet_timeout - $current_time) sec"
  if [ $testnet_timeout -le $current_time ]; then
    genesis_release=$(get_github_release $testnet_repository)
    if [ $genesis_release = $ITERATION_RELEASE ]; then
      echo "could not find new genesis release (release: $genesis_release)"
      return 0
    fi
    
    retention_reset $genesis_release
  fi
}

retention_reset() {
  local genesis_release=$1
  echo "reset testnet: $1"

  call_client_fn $selected_el_client "stop"
  call_client_fn $selected_cl_client "stop"

  call_client_fn $selected_el_client "clear"
  call_client_fn $selected_cl_client "clear"

  download_testnet_genesis $genesis_release
  call_client_fn $selected_el_client "init"

  call_client_fn $selected_el_client "start"
  call_client_fn $selected_cl_client "start"

  if [[ $(type -t on_reset) == function ]]; then
    on_reset $genesis_release
  fi
}

# client function wrapper
call_client_fn() {
  local client="$1"
  local action="$2"
  local fname="client_${client}_${action}"
  if [[ $(type -t $fname) == function ]]; then
    echo "call: $fname"
    $fname
  fi
}

# EL Clients
# geth
client_geth_name="geth"
client_geth_image="ethereum/client-go:stable"
client_geth_datadir="~base/geth"
client_geth_start() {
  local datadir=$(resolve_path "$client_geth_datadir")
  local confdir=$(resolve_path "$testnet_configdir")
  local jwtfile=$(resolve_path "$engine_auth_jwt")
  ensure_jwtsecret $jwtfile
  ensure_extip
  source $confdir/nodevars_env.txt
  mkdir -p $datadir
  docker run -d --restart unless-stopped \
    -u $UID:$GID \
    --name $client_geth_name \
    -v $datadir:/data \
    -v $jwtfile:/execution-auth.jwt:ro \
    -p ${port_el_http_rpc_addr}:${port_el_http_rpc}:${port_el_http_rpc} \
    -p ${port_el_engine_addr}:${port_el_engine}:${port_el_engine} \
    -p ${port_el_p2p}:${port_el_p2p} \
    -p ${port_el_p2p}:${port_el_p2p}/udp \
    -it ${client_geth_image} \
    --datadir=/data \
    --port=${port_el_p2p} \
    --http \
    --http.addr=0.0.0.0 \
    --http.port=${port_el_http_rpc} \
    --authrpc.addr=0.0.0.0 \
    --authrpc.port=${port_el_engine} \
    --authrpc.vhosts=* \
    --authrpc.jwtsecret=/execution-auth.jwt \
    --nat=extip:$extip \
    --syncmode=full \
    --bootnodes "${BOOTNODE_ENODE_LIST}" \
    --networkid ${CHAIN_ID}
}
client_geth_stop() {
  docker stop $client_geth_name
  docker rm $client_geth_name
}
client_geth_clear() {
  local datadir=$(resolve_path "$client_geth_datadir")
  if [ -d $datadir ]; then
    mv $datadir/geth/nodekey $datadir/nodekey
    rm -rf $datadir/geth
    mkdir -p $datadir/geth
    mv $datadir/nodekey $datadir/geth/nodekey
  fi
}
client_geth_init() {
  local datadir=$(resolve_path "$client_geth_datadir")
  local confdir=$(resolve_path "$testnet_configdir")
  source $confdir/nodevars_env.txt
  mkdir -p $datadir
  docker run --rm \
    -u $UID:$GID \
    --name ${client_geth_name}-init \
    -v $datadir:/data \
    -v $confdir:/config:ro \
    -it ${client_geth_image} \
    init \
    --datadir=/data \
    /config/genesis.json
}

# besu
client_besu_name="besu"
client_besu_image="hyperledger/besu:latest"
client_besu_datadir="~base/besu"
client_besu_start() {
  local datadir=$(resolve_path "$client_besu_datadir")
  local confdir=$(resolve_path "$testnet_configdir")
  local jwtfile=$(resolve_path "$engine_auth_jwt")
  ensure_jwtsecret $jwtfile
  ensure_extip
  source $confdir/nodevars_env.txt
  mkdir -p $datadir
  docker run -d --restart unless-stopped \
    -u $UID:$GID \
    --name $client_besu_name \
    -v $datadir:/data \
    -v $confdir:/config:ro \
    -v $jwtfile:/execution-auth.jwt:ro \
    -p ${port_el_http_rpc_addr}:${port_el_http_rpc}:${port_el_http_rpc} \
    -p ${port_el_engine_addr}:${port_el_engine}:${port_el_engine} \
    -p ${port_el_p2p}:${port_el_p2p} \
    -p ${port_el_p2p}:${port_el_p2p}/udp \
    -it ${client_besu_image} \
    --data-path=/data \
    --nat-method=NONE \
    --p2p-host=${extip} \
    --p2p-port=${port_el_p2p} \
    --rpc-http-enabled \
    --rpc-http-host=0.0.0.0 \
    --rpc-http-port=${port_el_http_rpc} \
    --rpc-http-cors-origins=* \
    --host-allowlist=* \
    --engine-jwt-secret=/execution-auth.jwt \
    --engine-rpc-port=${port_el_engine} \
    --engine-host-allowlist=* \
    --genesis-file=/config/besu.json \
    --bootnodes="${BOOTNODE_ENODE_LIST}" \
    --sync-mode=FULL
}
client_besu_stop() {
  docker stop $client_besu_name
  docker rm $client_besu_name
}
client_besu_clear() {
  local datadir=$(resolve_path "$client_besu_datadir")
  if [ -d $datadir ]; then
    rm -rf $datadir/*
  fi
}

# erigon
client_erigon_name="erigon"
client_erigon_image="thorax/erigon:stable"
client_erigon_datadir="~base/erigon"
client_erigon_start() {
  local datadir=$(resolve_path "$client_erigon_datadir")
  local confdir=$(resolve_path "$testnet_configdir")
  local jwtfile=$(resolve_path "$engine_auth_jwt")
  ensure_jwtsecret $jwtfile
  ensure_extip
  source $confdir/nodevars_env.txt
  mkdir -p $datadir
  docker run -d --restart unless-stopped \
    -u $UID:$GID \
    --name $client_erigon_name \
    -v $datadir:/data \
    -v $confdir:/config:ro \
    -v $jwtfile:/execution-auth.jwt:ro \
    -p ${port_el_http_rpc_addr}:${port_el_http_rpc}:${port_el_http_rpc} \
    -p ${port_el_engine_addr}:${port_el_engine}:${port_el_engine} \
    -p ${port_el_p2p}:${port_el_p2p} \
    -p ${port_el_p2p}:${port_el_p2p}/udp \
    --entrypoint erigon \
    -it ${client_erigon_image} \
    --datadir=/data \
    --nat=extip:${extip} \
    --port=${port_el_p2p} \
    --http \
    --http.addr=0.0.0.0 \
    --http.api=eth,erigon,engine,web3,net,debug,trace,txpool,admin \
    --http.vhosts=* \
    --http.port=${port_el_http_rpc} \
    --ws \
    --authrpc.jwtsecret=/execution-auth.jwt \
    --authrpc.port=${port_el_engine} \
    --authrpc.addr=0.0.0.0 \
    --authrpc.vhosts=* \
    --prune=htc \
    --bootnodes "${BOOTNODE_ENODE_LIST}" \
    --networkid ${CHAIN_ID}
}
client_erigon_stop() {
  docker stop $client_erigon_name
  docker rm $client_erigon_name
}
client_erigon_clear() {
  local datadir=$(resolve_path "$client_erigon_datadir")
  if [ -d $datadir ]; then
    rm -rf $datadir/*
  fi
}
client_erigon_init() {
  local datadir=$(resolve_path "$client_erigon_datadir")
  local confdir=$(resolve_path "$testnet_configdir")
  source $confdir/nodevars_env.txt
  mkdir -p $datadir
  docker run --rm \
    -u $UID:$GID \
    --name ${client_erigon_name}-init \
    -v $datadir:/data \
    -v $confdir:/config:ro \
    -it ${client_erigon_image} \
    --datadir=/data \
    init \
    /config/genesis.json
}

# nethermind
client_nethermind_name="nethermind"
client_nethermind_image="nethermind/nethermind:latest"
client_nethermind_datadir="~base/nethermind"
client_nethermind_start() {
  local datadir=$(resolve_path "$client_nethermind_datadir")
  local confdir=$(resolve_path "$testnet_configdir")
  local jwtfile=$(resolve_path "$engine_auth_jwt")
  ensure_jwtsecret $jwtfile
  ensure_extip
  source $confdir/nodevars_env.txt
  mkdir -p $datadir
  docker run -d --restart unless-stopped \
    -u $UID:$GID \
    --name $client_nethermind_name \
    -v $datadir:/data \
    -v $confdir:/config:ro \
    -v $jwtfile:/execution-auth.jwt:ro \
    -p ${port_el_http_rpc_addr}:${port_el_http_rpc}:${port_el_http_rpc} \
    -p ${port_el_engine_addr}:${port_el_engine}:${port_el_engine} \
    -p ${port_el_p2p}:${port_el_p2p} \
    -p ${port_el_p2p}:${port_el_p2p}/udp \
    --entrypoint /nethermind/Nethermind.Runner \
    -it ${client_nethermind_image} \
    --datadir=/data \
    --KeyStore.KeyStoreDirectory=/data/keystore \
    --Network.ExternalIp=${extip} \
    --Network.P2PPort=${port_el_p2p} \
    --Network.DiscoveryPort=${port_el_p2p} \
    --JsonRpc.Enabled=true \
    --JsonRpc.Host=0.0.0.0 \
    --JsonRpc.Port=${port_el_http_rpc} \
    --Init.WebSocketsEnabled=true \
    --JsonRpc.WebSocketsPort=${port_el_http_rpc} \
    --JsonRpc.JwtSecretFile=/execution-auth.jwt \
    --JsonRpc.EnginePort=${port_el_engine} \
    --JsonRpc.EngineHost=0.0.0.0 \
    --Init.IsMining=false \
    --Pruning.Mode=None \
    --config=none.cfg \
    --Init.ChainSpecPath=/config/chainspec.json \
    --JsonRpc.EnabledModules=Eth,Subscribe,Trace,TxPool,Web3,Personal,Proof,Net,Parity,Health,Rpc,Debug,Admin \
    --Discovery.Bootnodes="${BOOTNODE_ENODE_LIST}"
}
client_nethermind_stop() {
  docker stop $client_nethermind_name
  docker rm $client_nethermind_name
}
client_nethermind_clear() {
  local datadir=$(resolve_path "$client_nethermind_datadir")
  if [ -d $datadir ]; then
    rm -rf $datadir/*
  fi
}

# ethereumjs
client_ethereumjs_name="ethereumjs"
client_ethereumjs_image="g11tech/ethereumjs:latest"
client_ethereumjs_datadir="~base/ethereumjs"
client_ethereumjs_start() {
  local datadir=$(resolve_path "$client_ethereumjs_datadir")
  local confdir=$(resolve_path "$testnet_configdir")
  local jwtfile=$(resolve_path "$engine_auth_jwt")
  ensure_jwtsecret $jwtfile
  ensure_extip
  source $confdir/nodevars_env.txt
  mkdir -p $datadir
  docker run -d --restart unless-stopped \
    -u $UID:$GID \
    --name $client_ethereumjs_name \
    -v $datadir:/data \
    -v $confdir:/config:ro \
    -v $jwtfile:/execution-auth.jwt:ro \
    -p ${port_el_http_rpc_addr}:${port_el_http_rpc}:${port_el_http_rpc} \
    -p ${port_el_engine_addr}:${port_el_engine}:${port_el_engine} \
    -p ${port_el_p2p}:${port_el_p2p} \
    -p ${port_el_p2p}:${port_el_p2p}/udp \
    -it ${client_ethereumjs_image} \
    --dataDir=/data \
    --extIP=${extip} \
    --port=${port_el_p2p} \
    --rpc \
    --rpcAddr=0.0.0.0 \
    --rpcPort=${port_el_http_rpc} \
    --rpcCors=* \
    --rpcEngine \
    --jwt-secret=/execution-auth.jwt \
    --rpcEnginePort=${port_el_engine} \
    --rpcEngineAddr=0.0.0.0 \
    --gethGenesis=/config/genesis.json \
    --syncMode=full \
    --maxPeers=75 \
    --isSingleNode=true \
    --bootnodes="${BOOTNODE_ENODE_LIST}"
}
client_ethereumjs_stop() {
  docker stop $client_ethereumjs_name
  docker rm $client_ethereumjs_name
}
client_ethereumjs_clear() {
  local datadir=$(resolve_path "$client_ethereumjs_datadir")
  if [ -d $datadir ]; then
    rm -rf $datadir/*
  fi
}

# CL Clients
# lighthouse
client_lighthouse_name="lighthouse"
client_lighthouse_image="sigp/lighthouse:latest"
client_lighthouse_datadir="~base/lighthouse"
client_lighthouse_start() {
  local datadir=$(resolve_path "$client_lighthouse_datadir")
  local confdir=$(resolve_path "$testnet_configdir")
  local jwtfile=$(resolve_path "$engine_auth_jwt")
  ensure_jwtsecret $jwtfile
  ensure_extip
  source $confdir/nodevars_env.txt
  mkdir -p $datadir
  docker run -d --restart unless-stopped \
    -u $UID:$GID \
    --name $client_lighthouse_name \
    -v $datadir:/data \
    -v $jwtfile:/execution-auth.jwt:ro \
    -v $confdir:/config:ro \
    -p ${port_cl_http_rpc_addr}:${port_cl_http_rpc}:${port_cl_http_rpc} \
    -p ${port_cl_p2p}:${port_cl_p2p} \
    -p ${port_cl_p2p}:${port_cl_p2p}/udp \
    -it ${client_lighthouse_image} \
    lighthouse beacon_node \
    --datadir=/data \
    --disable-upnp \
    --disable-enr-auto-update \
    --enr-address=$extip \
    --enr-tcp-port=${port_cl_p2p} \
    --enr-udp-port=${port_cl_p2p} \
    --discovery-port=${port_cl_p2p} \
    --listen-address=0.0.0.0 \
    --port=${port_cl_p2p} \
    --http \
    --http-address=0.0.0.0 \
    --http-port=${port_cl_http_rpc} \
    --execution-jwt=/execution-auth.jwt \
    --execution-endpoint=${execution_url} \
    --testnet-dir /config \
    --boot-nodes=${BOOTNODE_ENR_LIST}
}
client_lighthouse_stop() {
  docker stop $client_lighthouse_name
  docker rm $client_lighthouse_name
}
client_lighthouse_clear() {
  local datadir=$(resolve_path "$client_lighthouse_datadir")
  if [ -d $datadir ]; then
    rm -rf $datadir/*
  fi
}

# prysm
client_prysm_name="prysm"
client_prysm_image="gcr.io/prysmaticlabs/prysm/beacon-chain:stable"
client_prysm_datadir="~base/prysm"
client_prysm_start() {
  local datadir=$(resolve_path "$client_prysm_datadir")
  local confdir=$(resolve_path "$testnet_configdir")
  local jwtfile=$(resolve_path "$engine_auth_jwt")
  local dcblock=$(cat "$confdir/deposit_contract_block.txt")
  ensure_jwtsecret $jwtfile
  ensure_extip
  source $confdir/nodevars_env.txt
  mkdir -p $datadir
  docker run -d --restart unless-stopped \
    -u $UID:$GID \
    --name $client_prysm_name \
    -v $datadir:/data \
    -v $jwtfile:/execution-auth.jwt:ro \
    -v $confdir:/config:ro \
    -p ${port_cl_http_rpc_addr}:${port_cl_http_rpc}:${port_cl_http_rpc} \
    -p ${port_cl_p2p}:${port_cl_p2p} \
    -p ${port_cl_p2p}:${port_cl_p2p}/udp \
    --entrypoint /app/cmd/beacon-chain/beacon-chain \
    -it ${client_prysm_image} \
    --accept-terms-of-use=true \
    --datadir=/data \
    --p2p-host-ip=$extip \
    --p2p-tcp-port=${port_cl_p2p} \
    --p2p-udp-port=${port_cl_p2p} \
    --rpc-host=0.0.0.0 \
    --rpc-port=4000 \
    --jwt-secret=/execution-auth.jwt \
    --execution-endpoint=${execution_url} \
    --grpc-gateway-host=0.0.0.0 \
    --grpc-gateway-port=${port_cl_http_rpc} \
    --grpc-gateway-corsdomain=* \
    --chain-config-file=/config/config.yaml \
    --genesis-state=/config/genesis.ssz \
    --contract-deployment-block=${dcblock} \
    --min-sync-peers=1 \
    --pprof \
    --bootstrap-node=${BOOTNODE_ENR}
}
client_prysm_stop() {
  docker stop $client_prysm_name
  docker rm $client_prysm_name
}
client_prysm_clear() {
  local datadir=$(resolve_path "$client_prysm_datadir")
  if [ -d $datadir ]; then
    rm -rf $datadir/*
  fi
}

# teku
client_teku_name="teku"
client_teku_image="consensys/teku:latest"
client_teku_datadir="~base/teku"
client_teku_start() {
  local datadir=$(resolve_path "$client_teku_datadir")
  local confdir=$(resolve_path "$testnet_configdir")
  local jwtfile=$(resolve_path "$engine_auth_jwt")
  ensure_jwtsecret $jwtfile
  ensure_extip
  source $confdir/nodevars_env.txt
  mkdir -p $datadir
  docker run -d --restart unless-stopped \
    -u $UID:$GID \
    --name $client_teku_name \
    -v $datadir:/data \
    -v $jwtfile:/execution-auth.jwt:ro \
    -v $confdir:/config:ro \
    -p ${port_cl_http_rpc_addr}:${port_cl_http_rpc}:${port_cl_http_rpc} \
    -p ${port_cl_p2p}:${port_cl_p2p} \
    -p ${port_cl_p2p}:${port_cl_p2p}/udp \
    -it ${client_teku_image} \
    --data-path=/data \
    --log-destination=CONSOLE \
    --p2p-enabled=true \
    --p2p-interface=0.0.0.0 \
    --p2p-advertised-ip=$extip \
    --p2p-port=${port_cl_p2p} \
    --p2p-advertised-port=${port_cl_p2p} \
    --rest-api-enabled \
    --rest-api-interface=0.0.0.0 \
    --rest-api-port=${port_cl_http_rpc} \
    --rest-api-host-allowlist=* \
    --ee-jwt-secret-file=/execution-auth.jwt \
    --ee-endpoint=${execution_url} \
    --network=/config/config.yaml \
    --initial-state=/config/genesis.ssz \
    --p2p-peer-upper-bound=100 \
    --p2p-discovery-bootnodes=${BOOTNODE_ENR_LIST}
}
client_teku_stop() {
  docker stop $client_teku_name
  docker rm $client_teku_name
}
client_teku_clear() {
  local datadir=$(resolve_path "$client_teku_datadir")
  if [ -d $datadir ]; then
    rm -rf $datadir/*
  fi
}

# lodestar
client_lodestar_name="lodestar"
client_lodestar_image="chainsafe/lodestar:latest"
client_lodestar_datadir="~base/lodestar"
client_lodestar_start() {
  local datadir=$(resolve_path "$client_lodestar_datadir")
  local confdir=$(resolve_path "$testnet_configdir")
  local jwtfile=$(resolve_path "$engine_auth_jwt")
  local dcblock=$(cat "$confdir/deposit_contract_block.txt")
  ensure_jwtsecret $jwtfile
  ensure_extip
  source $confdir/nodevars_env.txt
  mkdir -p $datadir
  docker run -d --restart unless-stopped \
    -u $UID:$GID \
    --name $client_lodestar_name \
    -v $datadir:/data \
    -v $jwtfile:/execution-auth.jwt:ro \
    -v $confdir:/config:ro \
    -p ${port_cl_http_rpc_addr}:${port_cl_http_rpc}:${port_cl_http_rpc} \
    -p ${port_cl_p2p}:${port_cl_p2p} \
    -p ${port_cl_p2p}:${port_cl_p2p}/udp \
    -it ${client_lodestar_image} \
    beacon \
    --dataDir=/data \
    --discv5 \
    --listenAddress=0.0.0.0 \
    --port=${port_cl_p2p} \
    --enr.ip=$extip \
    --enr.tcp=${port_cl_p2p} \
    --enr.udp=${port_cl_p2p} \
    --rest \
    --rest.address=0.0.0.0 \
    --rest.port=${port_cl_http_rpc} \
    --jwt-secret=/execution-auth.jwt \
    --execution.urls=${execution_url} \
    --paramsFile=/config/config.yaml \
    --genesisStateFile=/config/genesis.ssz \
    --rest.namespace="*" \
    --network.connectToDiscv5Bootnodes \
    --nat=true \
    --bootnodes=${BOOTNODE_ENR_LIST}
}
client_lodestar_stop() {
  docker stop $client_lodestar_name
  docker rm $client_lodestar_name
}
client_lodestar_clear() {
  local datadir=$(resolve_path "$client_lodestar_datadir")
  if [ -d $datadir ]; then
    rm -rf $datadir/*
  fi
}

# nimbus
client_nimbus_name="nimbus"
client_nimbus_image="statusim/nimbus-eth2:amd64-latest"
client_nimbus_datadir="~base/nimbus"
client_nimbus_start() {
  local datadir=$(resolve_path "$client_nimbus_datadir")
  local confdir=$(resolve_path "$testnet_configdir")
  local jwtfile=$(resolve_path "$engine_auth_jwt")
  local dcblock=$(cat "$confdir/deposit_contract_block.txt")
  ensure_jwtsecret $jwtfile
  ensure_extip
  source $confdir/nodevars_env.txt
  mkdir -p $datadir
  docker run -d --restart unless-stopped \
    -u $UID:$GID \
    --name $client_nimbus_name \
    -v $datadir:/data \
    -v $jwtfile:/execution-auth.jwt:ro \
    -v $confdir:/config:ro \
    -p ${port_cl_http_rpc_addr}:${port_cl_http_rpc}:${port_cl_http_rpc} \
    -p ${port_cl_p2p}:${port_cl_p2p} \
    -p ${port_cl_p2p}:${port_cl_p2p}/udp \
    -it ${client_nimbus_image} \
    --non-interactive=true \
    --data-dir=/data \
    --log-level=INFO \
    --listen-address=0.0.0.0 \
    --udp-port=${port_cl_p2p} \
    --tcp-port=${port_cl_p2p} \
    --nat=extip:$extip \
    --enr-auto-update=false \
    --rest \
    --rest-address=0.0.0.0 \
    --rest-port=${port_cl_http_rpc} \
    --rest-allow-origin=* \
    --jwt-secret=/execution-auth.jwt \
    --web3-url=${execution_url} \
    --network=/config \
    --validator-monitor-auto=false \
    --doppelganger-detection=off \
    --bootstrap-node=${BOOTNODE_ENR}
}
client_nimbus_stop() {
  docker stop $client_nimbus_name
  docker rm $client_nimbus_name
}
client_nimbus_clear() {
  local datadir=$(resolve_path "$client_nimbus_datadir")
  if [ -d $datadir ]; then
    rm -rf $datadir/*
  fi
}
