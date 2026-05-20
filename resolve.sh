#!/bin/bash
#
# This script resolves domains and routes them through Cloudflare's VPN/WARP tunnel.
# Make sure to run it as root.

echo -e "This script automates resolving domains and routing them through your WARP/VPN network."
echo -e "Make sure to add a static route for your tunnel endpoint via your netplan config file.\n"

ipv4interfaces=($(ip -br -4 a | grep -E "UP|UNKNOWN" | grep -v "br-" | awk '{print $1}'))
ipv4ips=($(ip -br -4 a | grep -E "UP|UNKNOWN" | grep -v "br-" | awk '{print $3}'))

# Check and install dependencies
bash dependencies.sh
chmod 777 ip.conf

# --- FUNCTION: Validate IPv4 ---
is_valid_ipv4() {
  local ip="${1%%/*}"  # strip /CIDR if present
  [[ $ip =~ ^(([0-9]|[1-9][0-9]|1[0-9]{2}|2[0-4][0-9]|25[0-5])\.){3}([0-9]|[1-9][0-9]|1[0-9]{2}|2[0-4][0-9]|25[0-5])$ ]]
}

# --- FUNCTION: Check interface status ---
interface_check() {
    check_if_up=$(ip -br -4 a | grep "$1" | awk '{print $2}')
    if [ "$check_if_up" = "DOWN" ] || [ -z "$check_if_up" ]; then
        return 0  # true: interface is down
    else
        return 1  # false: interface is up
    fi
}

# --- INTERFACE CONFIGURATION ---
if [ -e "interfaces.conf" ]; then
    saved_interfaces=($(cat interfaces.conf))
    for interface in "${saved_interfaces[@]}"; do
        if interface_check "${interface#*=}"; then
            echo "$interface is down, kindly check your network configuration."
            exit 1
        else
            echo "${interface#*=} is up"
        fi
    done
else
    echo "No interfaces have been configured yet."

    user_interface_input() {
        read -p "Enter a number: " inlannum
        if [[ "$inlannum" =~ ^[0-9]+$ ]] && [ "$inlannum" -lt "${#ipv4interfaces[@]}" ]; then
           echo "$1${ipv4interfaces[$inlannum]%%@*}"
        else
            echo "Invalid input!"
            user_interface_input "$1"
        fi
    }

    echo "Your interfaces:"
    ip -4 -br a | grep -E "UP|UNKNOWN" | grep -v "br-" | nl -v 0

    echo -n "Type your LAN interface number for incoming packets: "
    incoming_inter=$(user_interface_input "incoming=")
    echo -n "Type your LAN interface number for outgoing packets: "
    outgoing_inter=$(user_interface_input "outgoing=")
    echo -n "Type your tunnel interface number: "
    tunnel_inter=$(user_interface_input "tunnel=")

    echo "$incoming_inter" > interfaces.conf
    echo "$outgoing_inter" >> interfaces.conf
    echo "$tunnel_inter" >> interfaces.conf

    cat -n interfaces.conf
fi

# --- TABLE SETUP ---
table_name=$(cat tunnel_table.conf)
grep -q "^$table_name" /etc/iproute2/rt_tables || echo "256 $table_name" | sudo tee -a /etc/iproute2/rt_tables >/dev/null

echo -e "\nAdd domains or addresses to resolve and route through your tunnel.\n"

# --- FUNCTION: Add domain or IP ---
add_domain() {
    read -rp "Domain Name (type 'exit' to quit): " domain
    routing_table=$(cat tunnel_table.conf)

    # Exit
    if [ "$domain" = "exit" ]; then
        echo "Exiting..."
        exit 0
    fi

    # Service install
    if [ "$domain" = "install" ]; then
        if ! systemctl list-unit-files | grep -q "^tunnel_routing.service"; then
            echo "Installing the service.."
            mapfile -t logs < service.logs
            sudo bash install_service.sh
            printf '%s\n' "${logs[@]}"
        else
            echo "Service already installed.."
        fi
    fi

    # --- DIRECT IP HANDLING ---
    if [ "$domain" = "ip" ]; then
        read -rp "Enter the IP address you want to add: " ip_input

        if is_valid_ipv4 "$ip_input"; then
            if [[ ! "$ip_input" =~ / ]]; then
                ip_entry="$ip_input/32"
            else
                ip_entry="$ip_input"
            fi

            echo "$ip_entry" >> ip.conf
            echo "Added $ip_entry to ip.conf"

            if ! ipset list "$table_name" | grep -q "$ip_entry"; then
                sudo ipset add "$table_name" "$ip_entry"
                echo "Added routing rule for $ip_entry via table $table_name"
            else
                echo "Routing rule for $ip_entry already exists."
            fi

            echo "$ip_entry" >> persistent_ip.conf
            echo "$ip_entry saved to persistent_ip.conf"
        else
            echo "Invalid IP or CIDR format. Please try again."
        fi
        add_domain
        return
    fi

    # --- DOMAIN HANDLING ---
    if ping -c 1 -W 2 "$domain" &>/dev/null; then
        echo "$domain resolved to the following IPs:"

        # Save domain if new
        if ! grep -q "$domain" domains.conf 2>/dev/null; then
            echo "$domain" >> domains.conf
        fi

        ips=($(dig +short A "$domain"))
        ipsv6=($(dig +short AAAA "$domain"))

        # --- IPv6 Handling ---
        if ((${#ipsv6[@]})); then
            echo "Found ${#ipsv6[@]} IPv6 addresses."
            for ip in "${ipsv6[@]}"; do
                if ip -6 addr add "$ip/128" dev lo 2>/dev/null; then
                    ip -6 addr del "$ip/128" dev lo 2>/dev/null # cleanup test
                    if grep -q "$ip/128" ipv6.conf 2>/dev/null; then
                        echo "$ip/128 already exists."
                    else
                        echo "$ip/128" >> ipv6.conf
                        echo "$ip/128 added to ipv6.conf"
                    fi
                else
                    echo "Invalid IPv6 format for $ip"
                fi
            done
        else
            echo "No IPv6 addresses found for $domain"
        fi

        # Getting subdomain IPs
        subdomain_finder=($(subfinder -d "$domain" -silent | dnsx -a -resp -silent -no-color | awk '{print $NF}' | tr -d '[]'))

        if ((${#subdomain_finder[@]})); then
            echo "Getting subdomain IPs..."
            for subdomain_ip in "${subdomain_finder[@]}"; do
                if is_valid_ipv4 "$subdomain_ip"; then
                    if ! grep -q "$subdomain_ip/32" ip.conf 2>/dev/null; then
                        echo "$subdomain_ip/32" | sudo tee -a ip.conf >/dev/null
                        echo "$subdomain_ip/32 added to ip.conf"
                    else
                        echo "Subdomain IP: $subdomain_ip/32 already exists"
                    fi
                fi
            done
        else
            echo "No subdomains were found for: $domain"
        fi

        # --- IPv4 Handling ---
        if ((${#ips[@]})); then
            echo "Found ${#ips[@]} IPv4 addresses."
            for ip in "${ips[@]}"; do
                if grep -q "$ip/32" ip.conf 2>/dev/null; then
                    echo "$ip/32 already exists."
                else
                    if is_valid_ipv4 "$ip"; then
                        echo "$ip/32" | sudo tee -a ip.conf >/dev/null
                        echo "$ip/32 added to ip.conf"
                    fi
                fi
            done
        else
            echo "No IPv4 addresses found for $domain"
        fi
    else
        echo "Domain does not exist or there was a network issue."
    fi

    echo "Summarizing IP list"
    tmpfile=$(mktemp)
    cidr-merger ip.conf > "$tmpfile"
    mv "$tmpfile" ip.conf

    # Add rules for resolved IPs
    mapfile -t ip_file < ip.conf
    for ip in "${ip_file[@]}"; do
        if ! ipset test "$table_name" "$ip" 2>/dev/null; then
            sudo ipset add "$table_name" "$ip"
        fi
    done

    if ! ip rule | grep -q "$table_name" ; then
        echo "Adding routing rule for ipset: $table_name"
        sudo iptables -t mangle -A PREROUTING -m set --match-set "$table_name" dst -j MARK --set-mark 123
        sudo ip rule add fwmark 123 table "$table_name"
    fi

    add_domain
}

add_domain
