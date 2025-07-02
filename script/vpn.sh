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
read -p "Quel ID souhaitez-vous pour le container LXC ? [104] : " CONTAINER_ID
CONTAINER_ID=${CONTAINER_ID:-104}

read -p "Quel est le nom de votre container ? [ovpn] : " CONTAINER_NAME
CONTAINER_NAME=${CONTAINER_NAME:-ovpn}

CONTAINER_IP="${LXC_BASE}.${CONTAINER_ID}"

while true; do
    read -s -p "Entrez le mot de passe root du container : " ROOT_PASSWORD
    echo
    read -s -p "Confirmez le mot de passe : " PASSWORD_CONFIRM
    echo
    if [ "$ROOT_PASSWORD" = "$PASSWORD_CONFIRM" ]; then
        break
    else
        echo "❌ Les mots de passe ne correspondent pas. Veuillez réessayer."
    fi
done

read -p "Quelle est l'IP du serveur (pour DNAT) ? [172.16.1.110] : " SERVER1_IP
SERVER1_IP=${SERVER1_IP:-172.16.1.110}

read -p "Sur quel port voulez vous bind OpenVPN? [1194]: " D_PORT
D_PORT=${D_PORT:-1194}

# Création du container LXC basique sous Debian (modifie selon ton template et stockage)
pct create $CONTAINER_ID local:vztmpl/ubuntu-22.04-standard_22.04-1_amd64.tar.zst \
    --hostname $CONTAINER_NAME \
    --cores 1 \
    --memory 512 \
    --net0 name=eth0,bridge=$LXC_VMBR,ip=${CONTAINER_IP}/${LXC_CIDR},gw=${LXC_GATEWAY} \
    --rootfs local-lvm:5 \
    --password $ROOT_PASSWORD \
    --unprivileged 1 \
    --start 1

modprobe tun
LXC_CONF="/etc/pve/lxc/${CONTAINER_ID}.conf"

echo "lxc.cgroup2.devices.allow = c 10:200 rwm" >> "$LXC_CONF"
echo "lxc.mount.entry = /dev/net/tun dev/net/tun none bind,create=file" >> "$LXC_CONF"

pct reboot $CONTAINER_ID

pct exec $CONTAINER_ID -- wget https://git.io/vpn -O /root/openvpn-install.sh

pct exec $CONTAINER_ID -- bash /root/openvpn-install.sh

pct exec $CONTAINER_ID -- apt-get -y install libpam-ldap libnss-ldap nslcd


echo "[✓] OpenVPN est installé et l'authentification LDAP est configurée."
echo "[✓] Pour vous y connecter, importez le fichier sur la machine cliente et ajoutez la ligne auth-user-pass après auth SHA512 dans le fichier."
