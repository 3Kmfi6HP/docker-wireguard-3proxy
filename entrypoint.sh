#!/usr/bin/env bash

# Define a function to spawn a subprocess and add its PID to the PIDS array
function spawn {
    # If the PIDS variable is not already set, initialize it as an empty array
    if [[ -z ${PIDS+x} ]]; then PIDS=(); fi
    # Run the given command in the background and add its PID to the PIDS array
    "$@" &
    PIDS+=($!)
}

# Define a function to wait for all PIDs in the PIDS array to complete
function join {
    # If the PIDS variable is set and not empty
    if [[ ! -z ${PIDS+x} ]]; then
        # For each PID in the PIDS array
        for pid in "${PIDS[@]}"; do
            # Wait for the process with the given PID to complete
            wait "${pid}"
        done
    fi
}

# Define a function to kill all PIDs in the PIDS array and the ENTRYPOINT_PID
function on_kill {
    # If the PIDS variable is set and not empty
    if [[ ! -z ${PIDS+x} ]]; then
        # For each PID in the PIDS array
        for pid in "${PIDS[@]}"; do
            # Kill the process with the given PID, suppressing any errors
            kill "${pid}" 2>/dev/null
        done
    fi
    # Kill the process with the ENTRYPOINT_PID, suppressing any errors
    kill "${ENTRYPOINT_PID}" 2>/dev/null
}

# Define a function to log messages with different levels and colors
function log {
    local LEVEL="$1"                           # The log level (e.g., INFO, WARNING, ERROR)
    local MSG="$(date '+%D %T') [${LEVEL}] $2" # The log message with timestamp and level

    # Set the color of the message based on the log level
    case "${LEVEL}" in
    INFO*) MSG="\x1B[94m${MSG}" ;;    # Blue for INFO
    WARNING*) MSG="\x1B[93m${MSG}" ;; # Yellow for WARNING
    ERROR*) MSG="\x1B[91m${MSG}" ;;   # Red for ERROR
    *) ;;
    esac

    # Print the colored message and reset the color
    echo -e "${MSG}"
}
# Export the current process ID as ENTRYPOINT_PID
export ENTRYPOINT_PID="${BASHPID}"

# Set up trap to call on_kill function on EXIT and SIGINT signals
trap "on_kill" EXIT
trap "on_kill" SIGINT

# Define WireGuard and 3Proxy configuration file paths
_WIREGUARD_CONFIG="/etc/wireguard/wg.conf"
PROXY_CONFIG="/etc/3proxy.cfg"
PROXY_LOG="/var/log/3proxy.log"

# gen_conf function: Generate the WireGuard configuration file
function gen_conf {
    # Check if all required environment variables are set
    if [[ 
        -n "${WIREGUARD_INTERFACE_PRIVATE_KEY}" &&
        -n "${WIREGUARD_INTERFACE_DNS}" &&
        -n "${WIREGUARD_INTERFACE_ADDRESS}" &&
        -n "${WIREGUARD_PEER_PUBLIC_KEY}" &&
        -n "${WIREGUARD_PEER_ALLOWED_IPS}" &&
        -n "${WIREGUARD_PEER_ENDPOINT}" ]] \
        ; then
        # Write Interface configuration
        echo "[Interface]" >"$1"
        echo "PrivateKey = ${WIREGUARD_INTERFACE_PRIVATE_KEY}" >>"$1"
        echo "DNS = ${WIREGUARD_INTERFACE_DNS}" >>"$1"
        echo "Address = ${WIREGUARD_INTERFACE_ADDRESS}" >>"$1"
        echo >>"$1"
        # Write Peer configuration
        echo "[Peer]" >>"$1"
        echo "PublicKey = ${WIREGUARD_PEER_PUBLIC_KEY}" >>"$1"
        echo "AllowedIPs = ${WIREGUARD_PEER_ALLOWED_IPS}" >>"$1"
        echo "Endpoint = ${WIREGUARD_PEER_ENDPOINT}" >>"$1"
    else
        # Generate Warp configuration if variables are not set
        log "INFO" "Generating Warp config"
        warp >"$1"
    fi
}

# Check if WIREGUARD_CONFIG environment variable is set
if [ -n "${WIREGUARD_CONFIG}" ]; then
    # Copy the existing WireGuard configuration
    cp -f "${WIREGUARD_CONFIG}" "${_WIREGUARD_CONFIG}"
else
    # Generate a new WireGuard configuration
    log "INFO" "Generating WireGuard config"
    gen_conf "${_WIREGUARD_CONFIG}"
fi

# Bring up the WireGuard interface
wg-quick up wg
log "INFO" "Spawn WireGuard"

# Declare an associative array to store proxy users
declare -A PROXY_USERS

# check_and_add_proxy_user function: Check and add a proxy user to the PROXY_USERS array
function check_and_add_proxy_user {
    local user="${!1}"
    local pass="${!2}"
    # Check if the user is empty
    if [[ -z "${user}" ]]; then
        return 1
    fi
    # Check if the password is empty
    if [[ -z "${pass}" ]]; then
        log "ERROR" "empty password for user ${user} is not allowed!"
        exit 1
    fi
    # Check for duplicate users
    if [[ -n "${PROXY_USERS["${user}"]}" ]]; then
        log "WARNING" "duplicated user ${user}, overwriting previous password."
    fi
    # Add the user to the PROXY_USERS array
    PROXY_USERS["${user}"]="${pass}"
    log "INFO" "Add proxy user ${user}"
}

# Check if SOCKS5_PROXY_PORT or HTTP_PROXY_PORT are set, and if so, configure the proxy
if [[ -n "${SOCKS5_PROXY_PORT}" || -n "${HTTP_PROXY_PORT}" ]]; then

    # Add proxy users for single user short-hand and backward compatibility
    check_and_add_proxy_user PROXY_USER PROXY_PASS
    check_and_add_proxy_user SOCKS5_USER SOCKS5_PASS

    # Add proxy users for multi-user support
    USER_SEQ="1"
    USER_SEQ_END="false"
    while [[ "${USER_SEQ_END}" != "true" ]]; do
        check_and_add_proxy_user "PROXY_USER_${USER_SEQ}" "PROXY_PASS_${USER_SEQ}"
        STATUS=$?
        if [[ "${STATUS}" != 0 ]]; then
            USER_SEQ_END="true"
        fi
        USER_SEQ=$(("${USER_SEQ}" + 1))
    done

    # Write 3proxy configuration
    echo "nscache 65536" >"${PROXY_CONFIG}"
    for PROXY_USER in "${!PROXY_USERS[@]}"; do
        echo "users \"${PROXY_USER}:$(mycrypt "$(openssl rand -hex 16)" "${PROXY_USERS["${PROXY_USER}"]}")\"" >>"${PROXY_CONFIG}"
    done
    echo "log \"${PROXY_LOG}\" D" >>"${PROXY_CONFIG}"
    echo "logformat \"- +_L%t.%. %N.%p %E %U %C:%c %R:%r %O %I %h %T\"" >>"${PROXY_CONFIG}"
    echo "rotate 30" >>"${PROXY_CONFIG}"
    echo "external 0.0.0.0" >>"${PROXY_CONFIG}"
    echo "internal 0.0.0.0" >>"${PROXY_CONFIG}"
    if [[ "${#PROXY_USERS[@]}" -gt 0 ]]; then
        echo "auth strong" >>"${PROXY_CONFIG}"
    fi
    echo "flush" >>"${PROXY_CONFIG}"
    for PROXY_USER in "${!PROXY_USERS[@]}"; do
        echo "allow \"${PROXY_USER}\"" >>"${PROXY_CONFIG}"
    done
    echo "maxconn 384" >>"${PROXY_CONFIG}"
    if [[ -n "${SOCKS5_PROXY_PORT}" ]]; then
        echo "socks -p${SOCKS5_PROXY_PORT}" >>"${PROXY_CONFIG}"
    fi
    if [[ -n "${HTTP_PROXY_PORT}" ]]; then
        echo "proxy -p${HTTP_PROXY_PORT}" >>"${PROXY_CONFIG}"
    fi

    # Start 3proxy using the configuration
    log "INFO" "Write 3proxy config"
    spawn 3proxy "${PROXY_CONFIG}"
    log "INFO" "Spawn 3proxy"
    PROXY_ENABLED="true"
fi

# Set up WireGuard and iptables
log "INFO" "WireGuard become stable"
SUBNET=$(ip -o -f inet addr show dev eth0 | awk '{print $4}')
IPADDR=$(echo "${SUBNET}" | cut -f1 -d'/')
GATEWAY=$(route -n | grep 'UG[ \t]' | awk '{print $2}')
eval "$(ipcalc -np "${SUBNET}")"

ip -4 rule del not fwmark 51820 table 51820
ip -4 rule del table main suppress_prefixlength 0

ip -4 rule add prio 10 from "${IPADDR}" table 128
ip -4 route add table 128 to "${NETWORK}/${PREFIX}" dev eth0
ip -4 route add table 128 default via "${GATEWAY}"

ip -4 rule add prio 20 not fwmark 51820 table 51820
ip -4 rule add prio 20 table main suppress_prefixlength 0
# Change DNS servers
echo -e "nameserver 1.1.1.1\nnameserver 8.8.8.8" >/etc/resolv.conf

log "INFO" "Updated iptables"

# Run proxy up script if proxy is enabled and a script is provided
if [[ "${PROXY_ENABLED}" == "true" && -n "${PROXY_UP}" ]]; then
    spawn "${PROXY_UP}"
    log "INFO" "Spawn proxy up script: ${PROXY_UP}"
fi

# Run WireGuard up script if provided
if [[ -n "${WIREGUARD_UP}" ]]; then
    spawn "${WIREGUARD_UP}"
    log "INFO" "Spawn WireGuard up script: ${WIREGUARD_UP}"
fi

# Execute passed arguments as a command
if [[ $# -gt 0 ]]; then
    log "INFO" "Execute command line: $@"
    "$@"
fi

# Run in daemon mode if no arguments are passed or if daemon mode is set
if [[ $# -eq 0 || "${DAEMON_MODE}" == true ]]; then
    join
fi
