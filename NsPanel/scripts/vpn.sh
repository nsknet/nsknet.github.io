#!/bin/bash

# Fail fast: abort on the first error and on failures anywhere in a pipeline.
# (-u is intentionally omitted: some functions reference optional env vars such
#  as ALLOWED_SUBNETS that may legitimately be unset.)
set -eo pipefail


function install_open_vpn(){
	echo "========================================================================="
	echo "Install OpenVPN"
	curl -O https://raw.githubusercontent.com/angristan/openvpn-install/master/openvpn-install.sh
	chmod +x openvpn-install.sh
	AUTO_INSTALL=y ./openvpn-install.sh
	echo "Done"
	echo "========================================================================="
}
