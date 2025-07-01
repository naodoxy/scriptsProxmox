#!/bin/bash

# Si déjà défini, ne pas redemander
if [ -z "$LXC_NETWORK" ]; then
  read -p "Entrez le réseau (ex: 172.16.1.0/24) : " LXC_NETWORK
  read -p "Entrez la passerelle (gateway) : " LXC_GATEWAY

  # Découpe le réseau pour en extraire la base IP et CIDR
  LXC_BASE=$(echo "$LXC_NETWORK" | cut -d'.' -f1-3)
  LXC_CIDR=$(echo "$LXC_NETWORK" | cut -d'/' -f2)

  # Export pour rendre dispo dans les autres scripts
  export LXC_NETWORK
  export LXC_BASE
  export LXC_CIDR
  export LXC_GATEWAY
fi
