#!/bin/bash
shdir=$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )
source $shdir/ephemery-clients.lib.sh

# This script depends on docker!
# Ensure you have docker installed and current user has permissions to control docker containers.

# set base data directory and ensure existence (clients will use a subfolder for their data)
base_datadir=$shdir/data
mkdir -p $base_datadir

# supported el clients: geth, besu, erigon, nethermind, ethereumjs
selected_el_client="geth"

# supported el clients: geth, besu, erigon, nethermind, ethereumjs
selected_cl_client="lighthouse"

# ephemery config
#testnet_repository="ephemery-testnet/ephemery-genesis"
#testnet_configdir="~base/ephemery-config"

# external ip
#extip=""

# Ports
#port_el_p2p=30303
#port_el_http_rpc_addr=172.17.0.1
#port_el_http_rpc=8545
#port_el_engine_addr=172.17.0.1
#port_el_engine=8551

#port_cl_p2p=9000
#port_cl_http_rpc_addr=172.17.0.1
#port_cl_http_rpc=5052

# engine auth jwt
#engine_auth_jwt="~base/jwtsecret"

# execution endpoint
#execution_url="http://172.17.0.1:${port_el_engine}"


ephemery_node_main "$@"

