#!/usr/bin/env bash
# This script is to upgrade/update/patch the blockchain binary automatically with halt-height
# usage example: upgrade_at_halt_height.sh config.env
if [[ -z $1 ]]; then
  echo "Please provide a filename containing variables."
  exit 1
fi

source "$1"

function pkg_install () {
  echo "Installing ${SYSTEM_PACKAGES} ..."
  sudo apt-get -qq update
  sudo apt-get -qq install -y ${SYSTEM_PACKAGES}
}

function go_install () {
  echo "Installing go ..."
  wget -q https://go.dev/dl/go${GO_VERSION}.linux-amd64.tar.gz
  sudo rm -rf ${GO_INSTALL_DIR}/go ; mkdir -p ${GO_INSTALL_DIR} ; sudo tar -C ${GO_INSTALL_DIR} -xzf go${GO_VERSION}.linux-amd64.tar.gz
  rm go*linux-amd64.tar.gz
  echo "export GOPATH=${HOME}/go" >> ${HOME_DIR}/.profile
  echo "export GOBIN=${HOME}/go/bin" >> ${HOME_DIR}/.profile
  echo "export PATH=${PATH}:${CHAIN_DIR}/cosmovisor/current/bin:${GOBIN}:${GO_INSTALL_DIR}/go/bin" >> ${HOME_DIR}/.profile
  source ${HOME_DIR}/.profile
}

function make_install () {
  local BINARY_REPO_DIR=$(basename "${BINARY_REPO%.git}")

  echo "Installing ${BINARY_REPO} with ${BINARY_VERSION} of ${BINARY_REPO_DIR} ..."
  cd "${HOME_DIR}"
  git clone -b "${BINARY_VERSION}" "${BINARY_REPO}" &> /dev/null
  cd ${BINARY_REPO_DIR} && make install
  cd "${HOME_DIR}" && rm -rf ${BINARY_REPO_DIR}
}

function daemon_restart () {
  sudo systemctl daemon-reload
  sudo systemctl restart ${CHAIN_SERVICE}
}

function reconfigure () {
  SERVICE_FILE=`sudo systemctl status ${CHAIN_SERVICE} | grep Loaded | cut -d\( -f2 | cut -d\; -f1`

  echo "BINARY        : ${BINARY}"
  echo "CHAIN_DIR     : ${CHAIN_DIR}"
  echo "CHAIN_SERVICE : ${CHAIN_SERVICE}"
  echo "HALT_HEIGHT   : ${HALT_HEIGHT}"
  echo "SERVICE_FILE  : ${SERVICE_FILE}"

  sed -i "s/halt-height = .*/halt-height = $HALT_HEIGHT/" "${CHAIN_DIR}/config/app.toml"
  sudo sed -i 's/Restart=always/Restart=no/' "${SERVICE_FILE}"
  sudo sed -i 's/Environment="DAEMON_ALLOW_DOWNLOAD_BINARIES=true"/Environment="DAEMON_ALLOW_DOWNLOAD_BINARIES=false"/' "${SERVICE_FILE}"
  sudo sed -i 's/Environment="DAEMON_RESTART_AFTER_UPGRADE=true"/Environment="DAEMON_RESTART_AFTER_UPGRADE=false"/' "${SERVICE_FILE}"
  sudo sed -i '/^RestartSec=/d' "${SERVICE_FILE}"
}

function autopatch () {
while true; do
  LATEST_BLOCK_HEIGHT=$(curl -s localhost:${RPC_PORT}/status | jq -r '.result.sync_info.latest_block_height')
  if [[ ${LATEST_BLOCK_HEIGHT} == ${HALT_HEIGHT} ]]; then
    while true; do
      SERVICE_STATUS=`sudo systemctl status ${CHAIN_SERVICE} | grep Active | cut -d\( -f2 | cut -d\) -f1`
      if [[ "${SERVICE_STATUS}" = "dead" ]]; then
        echo "SERVICE_STATUS      : ${SERVICE_STATUS}"
	echo "Copying ..."
        cp ${GOBIN}/${BINARY} ${CHAIN_DIR}/cosmovisor/current/bin/${BINARY}
	echo "Reverting ..."
        sed -i "s/halt-height = .*/halt-height = 0/" "${CHAIN_DIR}/config/app.toml"
	sudo sed -i 's/Restart=no/Restart=always\nRestartSec=3/' "$SERVICE_FILE"
        sudo sed -i 's/Environment="DAEMON_ALLOW_DOWNLOAD_BINARIES=false"/Environment="DAEMON_ALLOW_DOWNLOAD_BINARIES=true"/' "${SERVICE_FILE}"
        sudo sed -i 's/Environment="DAEMON_RESTART_AFTER_UPGRADE=false"/Environment="DAEMON_RESTART_AFTER_UPGRADE=true"/' "${SERVICE_FILE}"
        daemon_restart
	echo "Exiting ..."
        exit
      fi
    done
  elif [[ ${LATEST_BLOCK_HEIGHT} != ${PREVIOUS_BLOCK_HEIGHT} ]]; then
      echo "LATEST_BLOCK_HEIGHT : ${LATEST_BLOCK_HEIGHT}"
  fi
  export PREVIOUS_BLOCK_HEIGHT=${LATEST_BLOCK_HEIGHT}
done
}

# Revoke functions
pkg_install
go_install
make_install
reconfigure
daemon_restart
autopatch
