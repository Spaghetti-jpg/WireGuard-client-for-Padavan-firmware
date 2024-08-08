# WireGuard Client for Padavan firmware with selective traffic routing for sites

This client was created primarily for personal use and specific tasks, one of which is selectively routing website traffic through a WireGuard VPN.

No opkg, no dig, no usb port.

## How It Works

The script reads the `domains.txt` file, resolves the domains using `nslookup` to get their IP addresses, and then adds them to an `ipset` table. After that, the script creates a configuration file for `dnsmasq` and writes the domains from `domains.txt` in the format `ipset=/domain.com/unblock-wg`. When new IPs are added to the `ipset` table, a timeout is set for them, after which the IP is removed, and a comment with the domain name is added for clarity. IP addresses are removed after 12 hours or 43,200 seconds. This removal is necessary to avoid routing domains that have changed their IP addresses. Dnsmask adds IP addresses to the IP address table only if the dns server makes a request for them.

Since `dnsmasq` cannot add IP addresses to `ipset` with a comment, I created a function to check for the presence of a comment in `ipset` entries. If there is no comment, the function will search for IP addresses in the `syslog.log` file and add the domain name from there. This is much faster than using `nslookup`, etc.

```sh
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
```
Thanks to ipset and dnsmasq, all subdomains of sites will be routed through the VPN, even if the subdomains are on a different IP address from the main domain, and you won’t have to create an entry for each subdomain.

## How to Use

```sh
./wg-client.sh start | stop | restart | update | clean
```

## Dependencies:
- Padavan firmware compiled with `CONFIG_FIRMWARE_INCLUDE_WIREGUARD=y`
- Ipset v7.11
- Dnsmasq v2.90
- Nslookup
- Presence of `syslog.log` file from `/sbin/syslogd` at `/tmp/syslog.log`
- DNS over HTTPS (optional)

## Installation and Configuration
1. Download or clone this repository to your PC.
2. Upload the project directory to the router with the command:
    ```sh
    scp -r <this repository> admin@192.168.1.1:/etc/storage
    ```
3. Connect via SSH to the router and navigate to the `/etc/storage/repo` directory.
4. Use `vi` to edit the `wg-client.sh` file and change these variables to your own values:
    ```sh
    IFACE="wg0"
    WG_SERVER="10.7.0.1"
    WG_CLIENT="10.7.0.2"
    WG_MASK="32"
    ```
    - `IFACE` is your WireGuard interface, leave it as is.
    - `WG_SERVER` is the address of your server in the WireGuard network. You can find it with the command `ip a show wg0` on your server. Example output:
      ```sh
      ~# ip a show wg0
      43: wg0: <POINTOPOINT,NOARP,UP,LOWER_UP> mtu 1280 qdisc noqueue state UNKNOWN group default qlen 1000
          link/none
          inet 10.7.0.1/32 scope global wg0
             valid_lft forever preferred_lft forever
      ```
    - `WG_CLIENT` is the address of your client in the WireGuard network, which is found in the config file created when you set up a new WireGuard user. The address is in the `[Interface]` section. Example:
      ```ini
      [Interface]
      Address = 10.7.0.2/24
      ```
    - `WG_MASK` is the mask of your WireGuard network.
5. Create the `wg0.conf` file in the project directory. The `wg0.conf` file should contain the configuration you get when you create a new WireGuard client.
6. Remove or comment out the `Address` and `DNS` lines from the `[Interface]` section. Example `wg0.conf`:
    ```ini
    [Interface]
    PrivateKey = your private key

    [Peer]
    PublicKey = your public key
    PresharedKey = your passphrase (optional)
    AllowedIPs = 0.0.0.0/0, ::/0
    Endpoint = the IP and port of your WireGuard server
    PersistentKeepalive = 25
    ```
7. Add the required domains to the `domains.txt` file. To check functionality, add the domain `ident.me`.
8. Go to the router’s web interface and open `dnsmasq.conf` via `LAN`, `DHCP Server`, `Additional Settings`, `User Configuration File (dnsmasq.conf)`. Add the following lines to this config:
    ```sh
    log-queries
    conf-file=/etc/storage/repo/unblock.dnsmasq
    ```
    Save the configuration.
For users whose ISP modifies DNS requests or who need DNS over HTTPS (optional):
If you compiled the firmware with the CONFIG_FIRMWARE_INCLUDE_DOH=y flag, you can use doh_proxy to enable DoH.

Run the command:

```sh
/usr/sbin/doh_proxy -4 -p 5353 -d -b 1.1.1.2,1.0.0.2 -r https://cloudflare-dns.com/dns-query
```

Add the following lines to the dnsmasq.conf file:
```sh
no-resolv
server=127.0.0.1#5353
```
## Work check

Run the command
```sh
curl --interface wg0 ident.me
```
If everything works, then you will receive the IP address of your Wireguard server
