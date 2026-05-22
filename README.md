# linux-split-tunnel-project
MY HOME NETWORK + WARP DOCKER + MACVLAN SETUP GUIDE
====================================================

This project was made to help me unblock certian websites, manage what goes through my main gateway and clear up the trrafic coming in and out of my network.

----------------------------------------------------

NETWORK OVERVIEW
----------------

My setup (adjust for your own setup):

- Home network: 192.168.1.0/24
- Server (host): 192.168.1.30/32  → interface: eno1
- Windows PC: 192.168.1.25/32
- Router (gateway): 192.168.1.1



----------------------------------------------------

This guide will assume you have a running and working docker installation on a Debian-based system.
Useful Linux networking commands you might wanna know:

ip a --> gets your current ip address and information, you can add flags like -br to get a brief, and -4 to get only ipv4 info.

docker ps ---> gets your running containers information. 

sudo docker network ls ---> gets your running or configured docker networks and bridges.

sudo docker network rm <id or name> --> deletes your docker network in case needed. 


----------------------------------------------------

----------------------------------------------------

STEP 1 — CREATE A MACVLAN NETWORK FOR DOCKER
-------------------------------------------
We’ll create a macvlan network with a specific IP range.
The --aux-address flag reserves one static IP for the host.

Command:

sudo docker network create -d macvlan   --subnet 192.168.1.0/24   --gateway 192.168.1.1   --ip-range 192.168.1.192/27   --aux-address 'host=192.168.1.223'   macvlan_docker

Notes:
- Replace IPs and names with your own.
- The range 192.168.1.192–223 will be used by Docker containers.
- The reserved IP 192.168.1.223 is for the host macvlan interface.

----------------------------------------------------

STEP 2 — CREATE HOST MACVLAN INTERFACE (SYSTEMD SERVICE)
--------------------------------------------------------
Create a service file: /etc/systemd/system/macvlan_interface.service

Contents:

[Unit]
Description=Create macvlan bridge interface
After=network-online.target NetworkManager.service
Wants=network-online.target NetworkManager.service

[Service]
Type=oneshot
ExecStart=/usr/sbin/ip link add local_macvlan link eno1 type macvlan mode bridge
ExecStart=/usr/sbin/ip addr add 192.168.1.223/32 dev local_macvlan
ExecStart=/usr/sbin/ip link set local_macvlan up
ExecStart=/usr/sbin/ip route add 192.168.1.192/27 dev local_macvlan
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target

Enable and start the service:

sudo systemctl enable macvlan_interface.service
sudo systemctl start macvlan_interface.service

Reference:
https://blog.oddbit.com/post/2018-03-12-using-docker-macvlan-networks/

----------------------------------------------------

STEP 3 — SET UP WARP DOCKER CONTAINER (BY CAOMINGJUN)
-----------------------------------------------------
Docs:
https://github.com/cmj2002/warp-docker/blob/main/docs/nat-gateway.md

Example Docker Compose (container IP: 192.168.1.195):

version: "3"

services:
  warp:
    image: caomingjun/warp
    container_name: warp
    restart: always
    device_cgroup_rules:
      - "c 10:200 rwm"
    ports:
      - "1080:1080"
    environment:
      - WARP_SLEEP=2
      - WARP_ENABLE_NAT=1
    cap_add:
      - MKNOD
      - AUDIT_WRITE
      - NET_ADMIN
    sysctls:
      - net.ipv6.conf.all.disable_ipv6=0
      - net.ipv4.conf.all.src_valid_mark=1
      - net.ipv4.ip_forward=1
      - net.ipv6.conf.all.forwarding=1
      - net.ipv6.conf.all.accept_ra=2
    volumes:
      - ./data:/var/lib/cloudflare-warp
    networks:
      macvlan_docker:
        ipv4_address: 192.168.1.195

networks:
  macvlan_docker:
    external: true

Test connectivity from the host:

ping 192.168.1.195

If you get a ping, your container is reachable.

----------------------------------------------------

STEP 4 — ENABLE NAT MASQUERADING ON THE HOST
---------------------------------------------
These commands make container traffic appear as coming from your WAN IP.

sudo iptables -t nat -A POSTROUTING -o <your_nic_name> -j MASQUERADE
sudo iptables -A FORWARD -i <your_nic_name> -o <your_nic_name> -j ACCEPT
sudo iptables -A FORWARD -i <your_nic_name> -o <your_nic_name> -m state --state ESTABLISHED,RELATED -j ACCEPT

Install and persist rules:

sudo apt install iptables-persistent
sudo netfilter-persistent save
sudo systemctl enable netfilter-persistent.service
sudo systemctl status netfilter-persistent.service

----------------------------------------------------

STEP 5 — SPLIT TUNNELING & DOMAIN RESOLVER SETUP
------------------------------------------------
Unpack resolve.zip, then:

1. Create a routing table (default name: warp) inside tunnel_table.conf, simply write the table name and the script will handle the rest.
2. Edit tunnel_ip and set your container’s IP, e.g. 192.168.1.195
3. Run:
   sudo bash resolve.sh

   Configure:
   - WAN interface 
   - LAN interface
     (in my case, I've used my eno1 as both the interface for outgoing and incoming packets)
   - Tunnel link (macvlan bridge)

4. Add domains you want resolved through the tunnel, or you can write 'ip' (without the quotation marks) and hit enter to provide presistant IPs instead of domains, make sure to provide the CIIDR, example (162.159.0.0/16 for a range) or (162.159.134.122/32) for a single host. 

5. Install and enable the resolver service:

   sudo install_service.sh
   systemctl enable tunnel_routing.service tunnel_routing.timer && systemctl enable tunnel_routing.service tunnel_routing.service 
   systemctl start tunnel_routing.service tunnel_routing.timer && systemctl start tunnel_routing.service tunnel_routing.service 


6. Check status:

   sudo systemctl status tunnel_routing.service

Your auto-resolver should now start at boot.

----------------------------------------------------

STEP 6 — RESETTING IPTABLES AND SETTINGS (IF THINGS BREAK)
----------------------------------------------

stop the container:

docker stop <container name or id used for the warp gate>

or 

docker rm <container name or id used for the warp gate> to delete it

to stop the service:

 sudo systemctl disable tunnel_routing.service tunnel_routing.timer && systemctl disable tunnel_routing.service tunnel_routing.service 
 sudo systemctl stop tunnel_routing.service tunnel_routing.timer && systemctl stop tunnel_routing.service tunnel_routing.service 


If you need to start over with clean firewall rules:

# Flush all rules
sudo iptables -F
sudo iptables -t nat -F
sudo iptables -t mangle -F

# Delete user-defined chains
sudo iptables -X
sudo iptables -t nat -X
sudo iptables -t mangle -X

# Reset counters and set default to ACCEPT
sudo iptables -Z
sudo iptables -P INPUT ACCEPT
sudo iptables -P FORWARD ACCEPT
sudo iptables -P OUTPUT ACCEPT

# Remove saved rules
sudo rm -f /etc/iptables/rules.v4 /etc/iptables/rules.v6

# Save clean state
sudo netfilter-persistent save

One-liner for IPv4:

sudo iptables -F; sudo iptables -t nat -F; sudo iptables -t mangle -F; sudo iptables -X; sudo iptables -Z; sudo iptables -P INPUT ACCEPT; sudo iptables -P FORWARD ACCEPT; sudo iptables -P OUTPUT ACCEPT

For IPv6:

sudo ip6tables -F
sudo ip6tables -t nat -F
sudo ip6tables -t mangle -F
sudo ip6tables -X
sudo ip6tables -t nat -X
sudo ip6tables -t mangle -X
sudo ip6tables -Z
sudo ip6tables -P INPUT ACCEPT
sudo ip6tables -P FORWARD ACCEPT
sudo ip6tables -P OUTPUT ACCEPT


after that reboot and you should be back to where you started

----------------------------------------------------

DONE
----
You now have:
- A working macvlan network for Docker
- A Cloudflare WARP NAT gateway container
- Persistent iptables rules
- Optional split tunneling and domain routing

**if everythign works, you can point devices on your network to use your Linux machine as a gateway instead of your main router, you can configure your DHCP server to use it as well**

