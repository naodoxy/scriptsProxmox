#!/bin/bash

[ -f /tmp/.network_env ] && source /tmp/.network_env

# Vérification que le script est exécuté en root
if [ "$EUID" -ne 0 ]; then
    echo "Ce script doit être exécuté en tant que root."
    exit 1
fi

TEMPLATE_NAME="ubuntu-22.04-standard_22.04-1_amd64.tar.zst"
TEMPLATE_PATH="/var/lib/vz/template/cache/$TEMPLATE_NAME"

# Vérification que la template existe
if [ ! -f "$TEMPLATE_PATH" ]; then
    echo "Template $TEMPLATE_NAME non trouvée. Téléchargement avec pveam..."
    pveam download local "$TEMPLATE_NAME"
    if [ $? -ne 0 ]; then
        echo "Échec du téléchargement de la template avec pveam."
        exit 1
    fi
    echo "Template téléchargée avec succès."
else
    echo "Template $TEMPLATE_NAME trouvée."
fi

# Questions à l'utilisateur
read -p "Quel est le nom de votre container ? [traefik] : " CONTAINER_NAME
CONTAINER_NAME=${CONTAINER_NAME:-traefik}

read -p "Quel est l'ID de votre container ? [102] : " CONTAINER_ID
CONTAINER_ID=${CONTAINER_ID:-102}

CONTAINER_IP="${LXC_BASE}.${CONTAINER_ID}"

while true; do
    read -s -p "Entrez le mot de passe root du container : " ROOT_PASSWORD
    echo
    read -s -p "Confirmez le mot de passe : " PASSWORD_CONFIRM
    echo

    if [ "$ROOT_PASSWORD" != "$PASSWORD_CONFIRM" ]; then
        echo "Les mots de passe ne correspondent pas. Veuillez réessayer."
    elif [ ${#ROOT_PASSWORD} -lt 5 ]; then
        echo "Le mot de passe doit contenir au moins 5 caractères. Veuillez réessayer."
    else
        break
    fi
done

read -p "Quelle est l'IP du serveur (pour DNAT) ? [172.16.1.110] : " SERVER_IP
SERVER_IP=${SERVER_IP:-172.16.1.110}

read -p "Sur quel port voulez vous accéder à l'interface web? [18110]: " D_PORT
D_PORT=${D_PORT:-18110}

echo "[*] Création du container LXC $CONTAINER_NAME avec IP $CONTAINER_IP..."

# Création du container LXC
pct create $CONTAINER_ID local:vztmpl/ubuntu-22.04-standard_22.04-1_amd64.tar.zst \
    --hostname $CONTAINER_NAME \
    --cores 1 \
    --memory 512 \
    --net0 name=eth0,bridge=$LXC_VMBR,ip=${CONTAINER_IP}/${LXC_CIDR},gw=${LXC_GATEWAY} \
    --rootfs local-lvm:5 \
    --password $ROOT_PASSWORD \
    --unprivileged 1 \
    --start 1

# Vérification de la création du conteneur
if [ $? -ne 0 ]; then
    echo "Échec de la création du conteneur LXC (ID: $CONTAINER_ID). Arrêt du script."
    exit 1
else
    echo "Conteneur LXC (ID: $CONTAINER_ID) créé avec succès."
fi

echo "[*] Installation de Traefik dans le container..."

pct exec $CONTAINER_ID -- bash -c "
cd /tmp && \
wget -q https://github.com/traefik/traefik/releases/download/v3.4.1/traefik_v3.4.1_linux_amd64.tar.gz && \
tar -xzf traefik_v3.4.1_linux_amd64.tar.gz && \
mv traefik /usr/local/bin/traefik && \
chmod +x /usr/local/bin/traefik && \
rm -f traefik_v3.4.1_linux_amd64.tar.gz
"

pct exec $CONTAINER_ID -- mkdir -p /etc/traefik/dynamic/

pct exec $CONTAINER_ID -- bash -c "cat > /etc/traefik/traefik.yml <<EOF
entryPoints:
  web:
    address: \":80\"

providers:
  file:
    directory: \"/etc/traefik/dynamic\"
    watch: true

api:
  dashboard: true
  insecure: true
EOF"

pct exec $CONTAINER_ID -- bash -c "cat > /etc/systemd/system/traefik.service <<EOF
[Unit]
Description=Traefik Service
After=network.target

[Service]
ExecStart=/usr/local/bin/traefik --configFile=/etc/traefik/traefik.yml
Restart=always

[Install]
WantedBy=multi-user.target
EOF"

pct exec $CONTAINER_ID -- bash -c "systemctl start traefik.service && systemctl enable traefik.service"

# Règles NAT
iptables -t nat -A PREROUTING -i vmbr0 -p tcp -d $SERVER_IP --dport 80 -j DNAT --to-destination $CONTAINER_IP:80
iptables -t nat -A POSTROUTING -s $CONTAINER_IP -o vmbr0 -j MASQUERADE
iptables -t nat -A PREROUTING -i vmbr0 -p tcp -d $SERVER_IP --dport $D_PORT -j DNAT --to-destination $CONTAINER_IP:8080
iptables-save > /etc/iptables.rules

echo "[✓] Traefik est maintenant installé et accessible sur http://$SERVER_IP:$D_PORT"
