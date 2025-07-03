#!/bin/bash

# Fonctions pour vérifier le format des IP et CIDR

is_valid_ip() {
  local ip=$1
  if [[ $ip =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
    IFS='.' read -r -a octets <<< "$ip"
    for octet in "${octets[@]}"; do
      if ((octet < 0 || octet > 255)); then
        return 1
      fi
    done
    return 0
  else
    return 1
  fi
}

is_valid_cidr() {
  local cidr=$1
  # Vérifie la forme IP/masque
  if [[ $cidr =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}/([0-9]{1,2})$ ]]; then
    local ip="${cidr%/*}"
    local prefix="${cidr#*/}"
    # Vérifie IP valide
    if ! is_valid_ip "$ip"; then
      return 1
    fi
    # Vérifie masque entre 0 et 32
    if ((prefix >= 1 && prefix <= 31)); then
      return 0
    else
      return 1
    fi
  else
    return 1
  fi
}

# Si déjà défini, ne pas redemander
if [ -z "$LXC_NETWORK" ]; then

  while true; do
    read -p "Entrez le réseau (ex: 172.16.1.0/24) : " LXC_NETWORK
    if is_valid_cidr "$LXC_NETWORK"; then
      break
    else
      echo "Erreur : réseau invalide. Format attendu : X.X.X.X/X avec masque entre 1 et 32."
    fi
  done

  while true; do
    read -p "Entrez la passerelle (gateway) : " LXC_GATEWAY
    if is_valid_ip "$LXC_GATEWAY"; then
      break
    else
      echo "Erreur : passerelle invalide. Format attendu : X.X.X.X"
    fi
  done

  read -p "Entrez le nom de la carte bridge de proxmox (par défaut vmbr0) : " LXC_VMBR
  LXC_VMBR=${LXC_VMBR:-vmbr0}

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
