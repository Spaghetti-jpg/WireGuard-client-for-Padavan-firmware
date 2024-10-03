#!/bin/sh

IFACE="wg0"
WG_SERVER="10.7.0.1"
WG_CLIENT="10.7.0.2"
WG_MASK="32"
MTU="1480"
WG_CONFIG="wg0.conf"
IPSET_NAME="unblock-list"

IPSET_TIMEOUT="43200"
COMMENT_UPDATE_INTERVAL="20"
DOMAINS_UPDATE_INTERVAL="10800"
IPSET_BACKUP_INTERVAL="10800"

DOMAINS_FILE="config/domains.lst"
CIDR_FILE="config/CIDR.lst"
DNSMASQ_FILE="config/unblock.dnsmasq"
SYSLOG_FILE="/tmp/syslog.log"
PID_FILE="/tmp/update_ipset.pid"
IPSET_BACKUP_FILE="config/ipset_backup.conf"
IPSET_BACKUP="false" # true/false

GREEN='\033[0;32m'
RED='\033[0;31m'
NC='\033[0m' # No Color

log() {
  local color=$2
  echo -e "${color}${1}${NC}" >&2
}

create_ipset() {
  if ! ipset list $IPSET_NAME > /dev/null 2>&1; then
    log "Creating ipset $IPSET_NAME with timeout and comments..." $GREEN
    ipset create $IPSET_NAME hash:net comment timeout $IPSET_TIMEOUT
  fi
}

restore_ipset() {
  if [ -f "$IPSET_BACKUP_FILE" ]; then
    ipset restore -exist -f "$IPSET_BACKUP_FILE"
    log "Ipset $IPSET_NAME restored from $IPSET_BACKUP_FILE." $GREEN
  fi
}

save_ipset() {
  if [ "$IPSET_BACKUP" = "true" ]; then
    ipset save $IPSET_NAME > "$IPSET_BACKUP_FILE"
    log "Ipset $IPSET_NAME saved to $IPSET_BACKUP_FILE." $GREEN
  fi
}

resolve_and_update_ipset() {
  log "Resolving domains and updating ipset $IPSET_NAME...\n"

  if [ ! -f "$DOMAINS_FILE" ]; then
    log "Error: File with unblockable resources $DOMAINS_FILE not found!" $RED
    exit 1
  fi

  : > $DNSMASQ_FILE

  resolve_domain() {
    local domain="$1"
    ADDR=$(nslookup $domain localhost | awk '/Address [0-9]+: / {ip=$3} /Address: / {ip=$2} ip ~ /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$/ && ip != "127.0.0.1" {print ip}')

    if [ -n "$ADDR" ]; then
      for IP_HOST in $ADDR; do
        ipset -exist add $IPSET_NAME $IP_HOST timeout $IPSET_TIMEOUT comment "$domain"
      done
    fi
    printf "ipset=/%s/%s\n" "$domain" "$IPSET_NAME" >> $DNSMASQ_FILE
  }

  while read -r line || [ -n "$line" ]; do
    [ -z "$line" ] && continue
    [ "${line:0:1}" = "#" ] && continue

    resolve_domain "$line" &
  done < $DOMAINS_FILE

  wait

  log "\nIpset $IPSET_NAME updated."
  log "Dnsmasq config file $DNSMASQ_FILE updated."
  log "Sending HUP signal to dnsmasq..."
  killall -HUP dnsmasq
}

update_ipset_from_cidr() {
  log "Adding CIDR to ipset $IPSET_NAME from $CIDR_FILE file..."

  if [ ! -f "$CIDR_FILE" ]; then
    log "Warning: CIDR file $CIDR_FILE not found!" $RED
    return
  fi

  while read -r cidr || [ -n "$cidr" ]; do
    [ -z "$cidr" ] && continue
    ipset -exist add $IPSET_NAME $cidr timeout $IPSET_TIMEOUT comment "$cidr"
  done < $CIDR_FILE

  log "Ipset $IPSET_NAME updated with CIDR ranges."
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
  local pid="$1"
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
  restore_ipset
  resolve_and_update_ipset
  update_ipset_from_cidr

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
      child_pid="$!"
      echo $child_pid >> $PID_FILE
      wait $child_pid
      remove_pid $child_pid
    done ) &

  echo "$!" >> $PID_FILE

  ( while true; do
      save_ipset
      sleep $IPSET_BACKUP_INTERVAL &
      child_pid="$!"
      echo $child_pid >> $PID_FILE
      wait $child_pid
      remove_pid $child_pid
    done ) &

  echo "$!" >> $PID_FILE

  ( while true; do
      update &
      sleep $DOMAINS_UPDATE_INTERVAL &
      child_pid="$!"
      echo $child_pid >> $PID_FILE
      wait $child_pid
      remove_pid $child_pid
    done ) &

  echo "$!" >> $PID_FILE

  if [ "$IPSET_BACKUP" != "true" ]; then
    log "Skipping ipset backup as IPSET_BACKUP is not true." $RED
  fi
}

stop() {
  log "\nStopping WireGuard interface $IFACE...\n" $RED

  if [ -f "$PID_FILE" ]; then
    xargs kill < "$PID_FILE"
    rm -f "$PID_FILE"
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
    update_ipset_from_cidr >/dev/null 2>&1
  else
    resolve_and_update_ipset
    update_ipset_from_cidr
  fi
}

clean() {
  log "Starting to clean ipset set: $IPSET_NAME..."

  if ipset list $IPSET_NAME > /dev/null 2>&1; then
    ipset flush $IPSET_NAME
    log "Ipset set $IPSET_NAME cleaned."
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