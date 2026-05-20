#!/bin/bash


   
working_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
service_name="tunnel_routing.service"


      echo  "This guide will help you set up the service for this bash script." 
      echo -n "Please type your default gateway(router ip): "
      

      #save the gateway ip, needs work
      read -r gateway_input
      echo "$gateway_input" > gateway.conf




      #building the service

      sudo chmod +x service.sh 

       #check and install dependencies
        bash dependencies.sh



         if systemctl list-unit-files | grep -q "^$service_name"; then
    if systemctl is-active --quiet "$service_name"; then
        echo "$service_name is already running — skipping creation."
        exit 0
    else
        echo "$service_name exists but is not running — continuing..."
    fi
else
    echo "$service_name does not exist — creating it now."
fi

 sudo tee /etc/systemd/system/tunnel_routing.service > /dev/null << EOF

[Unit]
Description=Update routing table via tunnel
After=network-online.target systemd-networkd-wait-online.service
Wants=network-online.target systemd-networkd-wait-online.service

[Service]
Type=oneshot
WorkingDirectory=$working_dir
ExecStart=$working_dir/service.sh
Environment="PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:/root/go/bin"
# Capture logs in journal
StandardOutput=journal
StandardError=journal
# Run as root (no need for sudo in script)
User=root
CapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_RAW
AmbientCapabilities=CAP_NET_ADMIN CAP_NET_RAW
NoNewPrivileges=yes


EOF


 sudo tee /etc/systemd/system/tunnel_routing.timer > /dev/null << EOF
[Unit]
Description=Run tunnel routing service periodically

[Timer]
# Run 1 minute after boot to ensure network is ready
OnBootSec=1min
# Run every 60 minutes
OnUnitActiveSec=60min
# Run missed jobs if the system was off
Persistent=true

Unit=tunnel_routing.service

[Install]
WantedBy=timers.target

EOF


sudo systemctl daemon-reload

sudo systemctl enable --now tunnel_routing.timer


