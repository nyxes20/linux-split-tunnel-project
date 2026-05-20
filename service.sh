#!/usr/bin/env bash
# fast-service.sh - Optimized tunnel routing service
# Must be run as root (systemd)

set -euo pipefail

# --- PATH & config ---
export PATH=/usr/sbin:/sbin:/usr/bin:/bin:/root/go/bin:$HOME/go/bin

mapfile -t domains_file < domains.conf
mapfile -t pres_ips_file < persistent_ip.conf
table_name=$(cat tunnel_table.conf)
default_gateway=$(cat gateway.conf)
tunnel_ip=$(cat tunnel_ip.conf)
tunnel_dev=$(grep "^tunnel=" interfaces.conf | cut -d'=' -f2 | cut -d'@' -f1)


#remove any empty lines in the files..

sed -i '/^$/d' persistent_ip.conf
sed -i '/^$/d' domains.conf
sed -i '/^$/d' ip.conf


logfile="service.logs"
echo "$(date): Starting tunnel routing service..." > "$logfile"

# --- IPv4 validator ---
is_valid_ipv4() {
    local ip="${1%%/*}"
    [[ $ip =~ ^(([0-9]|[1-9][0-9]|1[0-9]{2}|2[0-4][0-9]|25[0-5])\.){3}([0-9]|[1-9][0-9]|1[0-9]{2}|2[0-4][0-9]|25[0-5])$ ]]
}

# --- Wait for tunnel ---
while ! ip addr show dev "$tunnel_dev" &>/dev/null; do
    echo "$(date): Waiting for tunnel $tunnel_dev..." >> "$logfile"
    sleep 2
done
echo "$(date): Tunnel $tunnel_dev is up" >> "$logfile"

# --- Add default route ---
ip route replace default via "$tunnel_ip" table "$table_name"
echo "$(date): Default route via $tunnel_ip added for $table_name" >> "$logfile"

# --- Create ipset if missing ---
if ! ipset list "$table_name" &>/dev/null; then
    ipset create "$table_name" hash:net
    echo "$(date): Created ipset $table_name" >> "$logfile"
fi

# --- Resolve domains (parallel) ---
echo "$(date): Resolving domains..." >> "$logfile"
tmp_ips=$(mktemp)
resolve_domain() {
    local domain="$1"
    # main domain IPv4
    dig +short "$domain" | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' | awk '{print $1"/32"}'
    # subdomains
    subfinder -d "$domain" -silent | dnsx -a -resp -silent -no-color | awk '{print $NF"/32"}' | tr -d '[]'
}
export -f resolve_domain
printf "%s\n" "${domains_file[@]}" | xargs -n1 -P8 -I{} bash -c 'resolve_domain "{}"' > "$tmp_ips"

# --- Add persistent IPs ---
for pip in "${pres_ips_file[@]}"; do

      [[ -z "$pip" ]] && continue  # skip empty lines in the pers ips file..
    if ! ipset test "$table_name" "$pip" 2>/dev/null; then
        ipset add "$table_name" "$pip"
    fi


done

# --- Deduplicate & summarize ---
sort -u "$tmp_ips" | cidr-merger > ip.conf
rm "$tmp_ips"
echo "$(date): IP list summarized, total $(wc -l < ip.conf) entries" >> "$logfile"

# Ensure only valid IPv4 CIDRs are written
grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+(/[0-9]+)?$' ip.conf > clean.conf
mv clean.conf ip.conf

# --- Batch add IPs to ipset ---
tmp_ipset=$(mktemp)
while read -r ip; do
  echo "add $table_name $ip" >> "$tmp_ipset"
done < ip.conf
#flush ipset before restoring it 
ipset flush "$table_name" 2>/dev/null || true

ipset restore < "$tmp_ipset"
rm "$tmp_ipset"
echo "$(date): IPs added to ipset $table_name" >> "$logfile"




# --- Add iptables + ip rule if missing ---
if ! ip rule | grep -q "$table_name"; then
    iptables -t mangle -A PREROUTING -m set --match-set "$table_name" dst -j MARK --set-mark 123
    ip rule add fwmark 123 table "$table_name"
    echo "$(date): Added iptables + ip rule for $table_name" >> "$logfile"
fi

echo "$(date): Tunnel routing service completed successfully" >> "$logfile"
