#!/bin/bash
shdir=$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )
source $shdir/retention.lib.sh

# set base data directory and ensure existence (clients will use a subfolder for their data)
base_datadir=$shdir/data
mkdir -p $base_datadir

# supported el clients: geth, besu, erigon, nethermind, ethereumjs
selected_el_client="geth"

# supported cl clients: lighthouse, teku, prysm, lodestar, nimbus
selected_cl_client="lighthouse"


case "$1" in
  start)
    call_client_fn $selected_el_client "start"
    call_client_fn $selected_cl_client "start"
    ;;
  stop)
    call_client_fn $selected_el_client "stop"
    call_client_fn $selected_cl_client "stop"
    ;;
  *)
    retention_main
    ;;
esac
