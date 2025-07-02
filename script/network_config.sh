#!/bin/bash

# Si déjà défini, ne pas redemander
if [ -z "$LXC_NETWORK" ]; then
  read -p "Entrez le réseau (ex: 172.16.1.0/24) : " LXC_NETWORK
  read -p "Entrez la passerelle (gateway) : " LXC_GATEWAY
  read -p "Entrez le nom de la carte bridge de proxmox (par défaut vmbr0) : " LXC_VMBR

  # Découpe le réseau pour en extraire la base IP et CIDR
  LXC_BASE=$(echo "$LXC_NETWORK" | cut -d'.' -f1-3)
  LXC_CIDR=$(echo "$LXC_NETWORK" | cut -d'/' -f2)

# Exporter dans un fichier temporaire
cat <<EOF > /tmp/.network_env
LXC_BASE=$LXC_BASE
LXC_CIDR=$LXC_CIDR
LXC_GATEWAY=$LXC_GATEWAY
LXC_VMBR=$LXC_VMBR
EOF
fi
