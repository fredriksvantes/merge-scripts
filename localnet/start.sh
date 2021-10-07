#!/bin/bash
set -euo pipefail
SCRIPTDIR="$( cd -- "$(dirname "$0")" >/dev/null 2>&1 ; pwd -P )"

NEED_BESU="true"
NEED_TEKU="true"
NEED_GETH="true"
NEED_LIGHTHOUSE="true"
NEED_VALTOOLS="true"

cd "${SCRIPTDIR}"
source ../prep.sh

rm -rf "${SCRATCH}/localnet"
mkdir -p "${SCRATCH}/localnet"
mkdir -p "${SCRATCH}/localnet/data"
mkdir -p "${SCRATCH}/localnet/data/besu1"
mkdir -p "${SCRATCH}/localnet/data/besu2"

GENESIS_STATE="${SCRATCH}/localnet/genesis.ssz"
TERMINAL_TOTAL_DIFFICULTY=300

CONSENSUS_BOOTNODE="enr:-KG4QNndG4nlf0_K6G2NOQ_ifmraOlseY7ZbsDQ0NWk2pmxjE-bi6SQT4UGXIbRXLq3vbvxWuNkxxEgml6h18nCKyvoDhGV0aDKQNJ7Z9jEAAAEBAAAAAAAAAIJpZIJ2NIJpcIR_AAABiXNlY3AyNTZrMaEDLtDQNOGsr_iYx-sZkTPsZha9b9PaHe5pHub_YcbGuZyDdGNwgiMog3VkcIIjKA"
EXECUTION_BOOTNODE="enode://3a514176466fa815ed481ffad09110a2d344f6c9b78c1d14afc351c3a51be33d8072e77939dc03ba44790779b7a1025baf3003f6732430e20cd9b76d953391b3@127.0.0.1:30308"

echo "Generating consensus genesis state..."
eth2-testnet-genesis phase0 \
  --config consensus/phase0.yaml \
  --eth1-block 0x6342bde06c37c72e50401c7c6ca3a898c129da44cb647c1de60584c3b3414faa \
  --timestamp $(date +%s) \
  --mnemonics consensus/mnemonics.yaml \
  --state-output "${GENESIS_STATE}" \
  --tranches-dir "${SCRATCH}/localnet/validator-pubkeys"

# Create consensus testnet dir
BEACONSPEC_DIR="${SCRATCH}/localnet/beaconspec"
mkdir -p "${BEACONSPEC_DIR}"
cp "${GENESIS_STATE}" "${BEACONSPEC_DIR}/genesis.ssz"
echo "[]" > "${BEACONSPEC_DIR}/boot_enr.yaml"
echo "$CONSENSUS_BOOTNODE" > "${BEACONSPEC_DIR}/boostrap_nodes.txt"
cp consensus/config.yaml "${BEACONSPEC_DIR}/config.yaml"
echo "0" > "${BEACONSPEC_DIR}/deploy_block.txt"

# Make sure keys aren't locked from previous runs. Terrible for slashing but oh well...
find consensus/validator-keys -name '*.lock' -delete

tmux kill-session -t merge-localnet || true


echo "### Node 1 - Geth + Teku"
$GETH --datadir "${SCRATCH}/localnet/data/geth1" init execution/genesis.json
$GETH --datadir "${SCRATCH}/localnet/data/geth1" account import --password "execution/geth/passfile.txt" execution/signer.key
#  sh -c "$BESU --config-file execution/besu/config.toml --data-path \"${SCRATCH}/localnet/data/besu1\"  --p2p-port 30308 --rpc-http-port=8545 --node-private-key-file=execution/signer.key | tee \"${SCRATCH}/localnet/data/besu1/besu.log\"" \
tmux new-session -d -s merge-localnet \
  $GETH \
    --catalyst \
    --http \
    --http.api "engine,eth" \
    --http.port 8545 \
    --allow-insecure-unlock \
    --unlock "0xa94f5374fce5edbc8e2a8697c15331677e6ebf0b" \
    --password "execution/geth/passfile.txt" \
    --datadir "${SCRATCH}/localnet/data/geth1" \
    --nodekey "execution/signer.key" \
    --bootnodes "$EXECUTION_BOOTNODE" \
    --port 30308 \
    --syncmode full \
    --mine \
    --networkid 2337002 \
    console \
    \; set-option remain-on-exit on

tmux split-window -h -t merge-localnet \
  $TEKU \
    --eth1-endpoints http://127.0.0.1:8545 \
    --ee-fee-recipient-address=0xfe3b557e8fb62b89f4916b721be55ceb828dbd73 \
    --validator-keys "consensus/validator-keys/batch1/teku-keys:consensus/validator-keys/batch1/teku-secrets" \
    --validator-keys "consensus/validator-keys/batch2/teku-keys:consensus/validator-keys/batch2/teku-secrets" \
    --validators-keystore-locking-enabled=false \
    --network=consensus/config.yaml \
    --initial-state "${GENESIS_STATE}" \
    --Xnetwork-merge-total-terminal-difficulty=${TERMINAL_TOTAL_DIFFICULTY} \
    --p2p-private-key-file=consensus/teku/teku.key \
    --p2p-advertised-ip=127.0.0.1 \
    --p2p-port 9000 \
    --Xlog-include-p2p-warnings-enabled \
    --rest-api-enabled \
    --data-path "${SCRATCH}/localnet/data/teku1"


echo "### Node 2 - Geth + Teku"
$GETH --datadir "${SCRATCH}/localnet/data/geth2" init execution/genesis.json
tmux split-window -v -t %0 \
  $GETH \
    --catalyst \
    --http \
    --http.api "engine,eth" \
    --http.port 8546 \
    --datadir "${SCRATCH}/localnet/data/geth2" \
    --bootnodes "$EXECUTION_BOOTNODE" \
    --port 30304 \
    --syncmode full \
    --networkid 2337002 \
    console
# Use besu instead:
#sh -c "$BESU --config-file execution/besu/config.toml --data-path \"${SCRATCH}/localnet/data/besu2\"  --p2p-port 30309 --rpc-http-port=8546 --bootnodes \"${EXECUTION_BOOTNODE}\" | tee \"${SCRATCH}/localnet/data/besu2/besu.log\""

tmux split-window -v -t %1 \
  $TEKU \
    --eth1-endpoints http://127.0.0.1:8546 \
    --ee-fee-recipient-address=0xfe3b557e8fb62b89f4916b721be55ceb828dbd73 \
    --validator-keys "consensus/validator-keys/batch3/teku-keys:consensus/validator-keys/batch3/teku-secrets" \
    --validator-keys "consensus/validator-keys/batch4/teku-keys:consensus/validator-keys/batch4/teku-secrets" \
    --validators-keystore-locking-enabled=false \
    --network=consensus/config.yaml \
    --initial-state "${GENESIS_STATE}" \
    --Xnetwork-merge-total-terminal-difficulty=${TERMINAL_TOTAL_DIFFICULTY} \
    --p2p-advertised-ip=127.0.0.1 \
    --p2p-port 9001 \
    --Xlog-include-p2p-warnings-enabled \
    --p2p-discovery-bootnodes "${CONSENSUS_BOOTNODE}" \
    --p2p-static-peers "/ip4/127.0.0.1/tcp/9000/p2p/16Uiu2HAmFojnD68tVG9yKjHApYTvyjtnQ2nMbxJpoDNiMPGVdyGP" \
    --rest-api-enabled \
    --rest-api-port 5052 \
    --data-path "${SCRATCH}/localnet/data/teku2"


echo "### Node 3 - Geth + Lighthouse"
$GETH --datadir "${SCRATCH}/localnet/data/geth3" init execution/genesis.json
tmux split-window -v -t %2 \
  $GETH \
    --catalyst \
    --http \
    --http.api "engine,eth" \
    --http.port 8547 \
    --datadir "${SCRATCH}/localnet/data/geth3" \
    --bootnodes "$EXECUTION_BOOTNODE" \
    --port 30305 \
    --syncmode full \
    --networkid 2337002 \
    console

tmux split-window -v -t %3 \
  $LIGHTHOUSE \
    --spec mainnet \
    --testnet-dir "${BEACONSPEC_DIR}" \
    beacon_node \
    --purge-db \
    --datadir "${SCRATCH}/localnet/data/lighthouse1" \
    --boot-nodes "${CONSENSUS_BOOTNODE}" \
    --port 9002 \
    --dummy-eth1 \
    --http \
    --http-port 5053 \
    --http-allow-sync-stalled \
    --merge \
    --execution-endpoints http://127.0.0.1:8547 \
    --terminal-total-difficulty-override ${TERMINAL_TOTAL_DIFFICULTY}



tmux attach-session -t merge-localnet