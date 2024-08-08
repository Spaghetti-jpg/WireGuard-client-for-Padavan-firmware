#!/bin/sh

IFACE="wg0"
WG_SERVER="10.7.0.1"
WG_CLIENT="10.7.0.2"
WG_MASK="32"
WG_CONFIG="wg0.conf"
IPSET_NAME="unblock-list"
IPSET_TIMEOUT="18000"
MTU="1280"
DOMAINS_FILE="domains.txt"
DNSMASQ_FILE="unblock.dnsmasq"
SYSLOG_FILE="/tmp/syslog.log"
UPDATE_INTERVAL=20
PID_FILE="/tmp/wg2_update_ipset.pid"

log() {
  echo "$@" >&2
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
    log "Error: File with unblockable resources $DOMAINS_FILE not found!"
    exit 1
  fi

  : > $DNSMASQ_FILE

  while read -r line || [ -n "$line" ]; do
    [ -z "$line" ] && continue
    [ "${line:0:1}" = "#" ] && continue

    ADDR=$(nslookup $line localhost 2>/dev/null | awk '/^Address [0-9]*: / && $3 ~ /^[0-9]+\./ && $3 != "127.0.0.1" {print $3}')

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
            system("ipset del " ipset_name " " ip)
            system("ipset add " ipset_name " " ip " comment \"" domain "\"")
          }
        }
      }'
  done
}


start() {
  log "Starting WireGuard interface $IFACE..."

  if [ ! -f "$WG_CONFIG" ]; then
    log "Error: WireGuard config file $WG_CONFIG not found!"
    exit 1
  fi

  create_ipset
  resolve_and_update_ipset

  modprobe wireguard
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

  log "WireGuard interface $IFACE started."

  ( while true; do
      update_ipset_from_syslog
      sleep $UPDATE_INTERVAL
    done ) & echo $! > $PID_FILE
}

stop() {
  log "Stopping WireGuard interface $IFACE..."

  clean

  ip route del default dev $IFACE table 1
  ip rule del fwmark 1 table 1
  iptables -D PREROUTING -t mangle -m set --match-set $IPSET_NAME dst,src -j MARK --set-mark 1
  iptables -t nat -D POSTROUTING -o $IFACE -j SNAT --to $WG_CLIENT
  iptables -D INPUT -i $IFACE -j ACCEPT
  iptables -D FORWARD -i $IFACE -j ACCEPT
  ip link set $IFACE down
  ip link delete dev $IFACE

  log "WireGuard interface $IFACE stopped."

  if [ -f "$PID_FILE" ]; then
    PID=$(cat $PID_FILE)
    kill $PID
    rm -f $PID_FILE
  fi
}

update() {
  resolve_and_update_ipset
}

clean() {
  log "Cleaning ipset $IPSET_NAME..."

  if ipset list $IPSET_NAME > /dev/null 2>&1; then
    ipset flush $IPSET_NAME
    log "ipset $IPSET_NAME flushed."
  else
    log "ipset $IPSET_NAME does not exist."
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
    log "Usage: $0 start, stop, restart, update, clean"
    exit 1
    ;;
esac
