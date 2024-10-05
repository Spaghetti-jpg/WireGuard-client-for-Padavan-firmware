# WireGuard client for routers based on Padavan firmware with the function of selective routing of traffic via VPN


This client was created primarily for personal use and specific tasks, one of which is selectively routing website traffic through a WireGuard VPN.

No opkg, no dig, no usb port.

# Only for bypassing geo-blocks!

## How It Works

The script reads the `domains.lst` file, resolves the domains using `nslookup` to get their IP addresses, and then adds them to the `ipset` table. The script then creates a configuration file for `dnsmasq` and writes the domains from `domains.lst` into it in the format `ipset=/domain.com/unblock-list`. When new IP addresses are added to the `ipset` table, they are given a timeout, after which the IP address is deleted, and a comment with the domain name is added for clarity. IP addresses are deleted after 12 hours or 43,200 seconds. This deletion is necessary to avoid routing domains that have changed their IP addresses. To keep the set of top domain IP addresses from the `domains.lst` file up to date, the script will update them every 6 hours (21,600 seconds). Dnsmasq adds IP addresses to the IP address table only if a DNS server makes a query for them.

Resolving domains from the `domains.lst` file is performed asynchronously, which allows you to work with large lists of domains. The number of threads is limited to 30 in the `MAX_PARALLEL_PROCESSES` variable. 

> [!WARNING]  
> Do not increase the value of `MAX_PARALLEL_PROCESSES` beyond 30 to avoid router hangs! 
My router has 64 MB, for this amount of DRAM, 30 threads is considered the optimal value. Do not try to increase this value with less DRAM!

Every 3 hours (10,800 seconds) the update function is called, which resolve the domains from `domains.lst` to IP addresses and adds them to the set of IP addresses to keep it up-to-date. The time before the update is declared in the variable `DOMAINS_UPDATE_INTERVAL`

Implementation of "asynchronous" domain resolution using `nslookup` allowed to speed up work with a large list of domains in domains.lst

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
            system("ipset -! add " ipset_name " " ip " comment \"" domain "\"")
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

- start - starts the client
- stop - stops the client
- restart - restarts the client
- update - re-resolves IP domains from domains.lst (Use if you added new domains to domains.lst)
- clean - cleans the Ipset table. After startup either use update or Dnsmasq will add IP addresses to Ipset as you visit sites from the `unblock.dnsmasq` list. 

## Dependencies:
- Padavan firmware compiled with `CONFIG_FIRMWARE_INCLUDE_WIREGUARD=y`
- BusyBox v1.36.1 built-in shell (ash)
- Ipset v7.11
- Dnsmasq v2.90
- Nslookup
- Presence of `syslog.log` file from `/sbin/syslogd` at `/tmp/syslog.log`
- DNS over HTTPS (optional)

## Installation and Configuration
1. Download or clone this repository to your PC.
2. Upload the project directory to the router with the command:
    ```sh
    scp -r WireGuard-client-for-Padavan-firmware admin@192.168.1.1:/etc/storage
    ```
3. Connect via SSH to the router and navigate to the `/etc/storage/WireGuard-client-for-Padavan-firmware` directory.
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
7. Make the `wg-client.sh` file executable using the command:
    ```sh
    chmod +x wg-client.sh
    ```
8. Run wg-client with the command `wg-client.sh start`
9. Add the required domains to the `domains.lst` file. To check functionality, add the domain `ident.me`.
10. Go to the router’s web interface and open `dnsmasq.conf` via `LAN`, `DHCP Server`, `Additional Settings`, `Custom Configuration File "dnsmasq.conf"`. Add the following lines to this config:
    ```sh
    log-queries
    conf-dir=/etc/storage/WireGuard-client-for-Padavan-firmware/Dnsmasq/config/
    ```
    Save the configuration.
11. To automatically run the script after turning on the router, you can place the command (optional)
    ```sh
    (cd /etc/storage/WireGuard-client-for-Padavan-firmware && ./wg-client.sh start >/dev/null 2>&1) &
    ```
    in the file `/etc/storage/started_script.sh` or use the router's web interface by going to `Customization`, `Scripts`, `Run After Router Started`.
12. The script implements IPset backup and recovery. If your power goes out or you frequently reboot your router, you can change the value of the `IPSET_BACKUP="false"` variable to true in the script code, the backup will be saved along the path `config/ipset_backup.conf`. Backup occurs every 3 hours, its time is declared in the `IPSET_BACKUP_INTERVAL` variable. Restoration from the backup occurs when the script is restarted (`wg-client.sh start`)
13. For users whose ISP modifies DNS requests or who need DNS over HTTPS (optional).
If you compiled the firmware with the `CONFIG_FIRMWARE_INCLUDE_DOH=y` flag, you can use doh_proxy to enable DoH. Run the command:

    ```sh
    /usr/sbin/doh_proxy -4 -p 5353 -d -b 1.1.1.2,1.0.0.2 -r https://cloudflare-dns.com/dns-query
    ```
    Add the following lines to the dnsmasq.conf file:
    ```sh
    no-resolv
    server=127.0.0.1#5353
    ```
    To autorun this command, you can add it to the webui under `Customization`, `Scripts`, `Run After Router Started`.
## Work check

Run the command
```sh
curl --interface wg0 ident.me
```
If everything works, then you will receive the IP address of your Wireguard server

## Example of Ipset table
```sh
ipset -L
Name: unblock-list
Type: hash:net
Revision: 7
Header: family inet hashsize 1024 maxelem 65536 timeout 18000 comment bucketsize 12 initval 0x662602a5
Size in memory: 3585
References: 1
Number of entries: 40
Members:
172.67.6.182 timeout 17882 comment "4pda.to"
142.250.203.142 timeout 17965 comment "youtube-ui.l.google.com"
216.58.215.110 timeout 17965 comment "youtube-ui.l.google.com"
142.250.186.214 timeout 17966 comment "i.ytimg.com"
130.255.77.28 timeout 17877 comment "ntc.party"
193.46.255.29 timeout 17879 comment "rutor.info"
172.217.130.145 timeout 17991 comment "rr1.sn-axq7sn76.googlevideo.com"
188.93.16.211 timeout 17879 comment "speedtest.selectel.ru"
142.250.203.214 timeout 17966 comment "i.ytimg.com"
49.12.234.183 timeout 17884 comment "ident.me"
142.250.75.14 timeout 17884 comment "youtu.be"
85.119.149.3 timeout 17875 comment "selectel.ru"
216.58.209.22 timeout 17966 comment "i.ytimg.com"
142.250.186.206 timeout 17967 comment "youtube-ui.l.google.com"
216.58.208.193 timeout 17876 comment "yt3.ggpht.com"
142.250.203.206 timeout 17968 comment "youtube-ui.l.google.com"
172.217.16.22 timeout 17968 comment "i.ytimg.com"
34.160.111.145 timeout 17876 comment "ifconfig.me"
104.22.35.226 timeout 17882 comment "4pda.to"
195.201.201.32 timeout 17875 comment "2ip.ru"
142.250.186.193 timeout 17991 comment "photos-ugc.l.googleusercontent.com"
104.21.50.150 timeout 17878 comment "static.rutracker.cc"
172.217.16.14 timeout 17969 comment "youtube-ui.l.google.com"
172.217.16.46 timeout 17969 comment "youtube-ui.l.google.com"
206.253.89.128 timeout 17882 comment "apis.google.com"
172.217.131.105 timeout 17969 comment "rr4.sn-q4flrnle.googlevideo.com"
104.22.34.226 timeout 17882 comment "4pda.to"
173.194.163.23 timeout 17992 comment "rr5.sn-axq7sn7z.googlevideo.com"
188.114.96.11 timeout 17881 comment "returnyoutubedislikeapi.com"
216.58.215.78 timeout 17883 comment "play.google.com"
142.250.75.22 timeout 17969 comment "i.ytimg.com"
172.217.16.54 timeout 17970 comment "i.ytimg.com"
216.58.208.206 timeout 17970 comment "youtube-ui.l.google.com"
216.58.215.86 timeout 17970 comment "i.ytimg.com"
142.250.203.150 timeout 17971 comment "i.ytimg.com"
188.114.97.11 timeout 17881 comment "returnyoutubedislikeapi.com"
173.194.57.170 timeout 17971 comment "rr5.sn-q4fl6n66.googlevideo.com"
216.58.209.14 timeout 17992 comment "youtube.com"
172.67.163.237 timeout 17878 comment "static.rutracker.cc"
142.250.203.132 timeout 17878 comment "googlevideo.com"
```
