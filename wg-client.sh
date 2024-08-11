#!/bin/sh

IFACE="wg0"
WG_SERVER="10.7.0.1"
WG_CLIENT="10.7.0.2"
WG_MASK="32"
WG_CONFIG="wg0.conf"
IPSET_NAME="unblock-list"
IPSET_TIMEOUT="43200"
MTU="1280"
DOMAINS_FILE="domains.txt"
DNSMASQ_FILE="unblock.dnsmasq"
SYSLOG_FILE="/tmp/syslog.log"
COMMENT_UPDATE_INTERVAL=20
DOMAINS_UPDATE_INTERVAL=21600
PID_FILE="/tmp/update_ipset.pid"

GREEN='\033[0;32m'
RED='\033[0;31m'
NC='\033[0m' # No Color

log() {
  local color=$2
  echo -e "${color}${1}${NC}" >&2
}

create_ipset() {
  if ! ipset list $IPSET_NAME > /dev/null 2>&1; then
    log "Creating ipset $IPSET_NAME with timeout and comments..."
    ipset create $IPSET_NAME hash:net comment timeout $IPSET_TIMEOUT
  fi
}

resolve_and_update_ipset() {
  log "Resolving domains and updating ipset $IPSET_NAME..."

  if [ ! -f "$DOMAINS_FILE" ]; then
    log "Error: File with unblockable resources $DOMAINS_FILE not found!" $RED
    exit 1
  fi

  : > $DNSMASQ_FILE

  while read -r line || [ -n "$line" ]; do
    [ -z "$line" ] && continue
    [ "${line:0:1}" = "#" ] && continue

    ADDR=$(nslookup $line localhost | awk '/Address [0-9]+: / {ip=$3} /Address: / {ip=$2} ip ~ /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$/ && ip != "127.0.0.1" {print ip}')

    if [ -n "$ADDR" ]; then
      for IP_HOST in $ADDR; do
        ipset -exist add $IPSET_NAME $IP_HOST timeout $IPSET_TIMEOUT comment "$line"
      done
    fi
    printf "ipset=/%s/%s\n" "$line" "$IPSET_NAME" >> $DNSMASQ_FILE
  done < $DOMAINS_FILE

  log "ipset $IPSET_NAME updated."
  log "dnsmasq config file $DNSMASQ_FILE updated."
  log "Sending HUP signal to dnsmasq..."
  killall -HUP dnsmasq
}

update_ipset_from_syslog() {
  ipset list $IPSET_NAME | grep '^ *[0-9]' | grep -v 'comment' | awk '{print $1}' | while read -r ip; do
    grep "reply .* is ${ip}" $SYSLOG_FILE | awk -v ip="${ip}" -v ipset_name="$IPSET_NAME" '
      {
        for (i=1; i<=NF; i++) {
          if ($i == "reply") {
            domain = $(i+1)
          }
          if ($NF == ip) {
            system("ipset -! add " ipset_name " " ip " comment \"" domain "\"")
          }
        }
      }'
  done
}

remove_pid() {
  local pid=$1
  sed -i "/^${pid}$/d" $PID_FILE
}

start() {
  log "\nStarting WireGuard interface $IFACE...\n" $GREEN

  modprobe wireguard
  modprobe ip_set
  modprobe ip_set_hash_ip
  modprobe ip_set_hash_net
  modprobe ip_set_bitmap_ip
  modprobe ip_set_list_set
  modprobe xt_set

  if [ ! -f "$WG_CONFIG" ]; then
    log "Error: WireGuard config file $WG_CONFIG not found!" $RED
    exit 1
  fi

  create_ipset
  resolve_and_update_ipset

  ip link add dev $IFACE type wireguard
  ip addr add $WG_CLIENT/$WG_MASK dev $IFACE
  wg setconf $IFACE "$WG_CONFIG"
  ip link set $IFACE up
  ip link set mtu $MTU dev $IFACE
  iptables -A FORWARD -i $IFACE -j ACCEPT

  echo 0 > /proc/sys/net/ipv4/conf/$IFACE/rp_filter

  iptables -I INPUT -i $IFACE -j ACCEPT
  iptables -t nat -I POSTROUTING -o $IFACE -j SNAT --to $WG_CLIENT
  iptables -A PREROUTING -t mangle -m set --match-set $IPSET_NAME dst,src -j MARK --set-mark 1
  ip rule add fwmark 1 table 1
  ip route add default dev $IFACE table 1
  ip route add $WG_SERVER/$WG_MASK dev $IFACE

  log "\nWireGuard interface $IFACE started.\n" $GREEN

  ( while true; do
      update_ipset_from_syslog
      sleep $COMMENT_UPDATE_INTERVAL &
      child_pid=$!
      echo $child_pid >> $PID_FILE
      wait $child_pid
      remove_pid $child_pid
    done ) &
  echo $! >> $PID_FILE

  ( while true; do
      update
      sleep $DOMAINS_UPDATE_INTERVAL &
      child_pid=$!
      echo $child_pid >> $PID_FILE
      wait $child_pid
      remove_pid $child_pid
    done ) &
  echo $! >> $PID_FILE
}

stop() {
  log "\nStopping WireGuard interface $IFACE...\n" $RED

  if [ -f "$PID_FILE" ]; then
    while read -r PID; do
      kill $PID
    done < $PID_FILE
    rm -f $PID_FILE
  fi

  clean

  ip route del default dev $IFACE table 1
  ip rule del fwmark 1 table 1
  iptables -D PREROUTING -t mangle -m set --match-set $IPSET_NAME dst,src -j MARK --set-mark 1
  iptables -t nat -D POSTROUTING -o $IFACE -j SNAT --to $WG_CLIENT
  iptables -D INPUT -i $IFACE -j ACCEPT
  iptables -D FORWARD -i $IFACE -j ACCEPT
  ip link set $IFACE down
  ip link delete dev $IFACE

  log "\nWireGuard interface $IFACE stopped.\n" $RED
}

update() {
  if [ -f "$PID_FILE" ]; then
    resolve_and_update_ipset >/dev/null 2>&1
  else
    resolve_and_update_ipset
  fi
}

clean() {
  log "Starting to clean ipset set: $IPSET_NAME..."

  if ipset list $IPSET_NAME > /dev/null 2>&1; then
    ipset flush $IPSET_NAME
    log "Ipset set $IPSET_NAME successfully flushed."
  else
    log "Ipset set $IPSET_NAME does not exist."
  fi
}


trap 'log "Script interrupted, cleaning up..."; stop; exit 1' INT TERM

case "$1" in
  start)
    start
    ;;
  stop)
    stop
    ;;
  restart)
    stop
    start
    ;;
  update)
    update
    ;;
  clean)
    clean
    ;;
  *)
    log "Usage: $0 start, stop, restart, update, clean" $RED
    exit 1
    ;;
esac
