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
read -p "Quel ID souhaitez-vous pour le container LXC ? [101] : " CONTAINER_ID
CONTAINER_ID=${CONTAINER_ID:-101}

read -p "Quel est le nom de votre container ? [dns-rec] : " CONTAINER_NAME
CONTAINER_NAME=${CONTAINER_NAME:-dns-rec}

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

read -p "Entrez le nom de votre zone/domaine [int.com]: " YOUR_DOMAIN
YOUR_DOMAIN=${YOUR_DOMAIN:-int.com}

read -p "Quelle est l'IP du serveur DNS Authoritative? [192.168.30.100]: " DNS_AUTH_IP
DNS_AUTH_IP=${DNS_AUTH_IP:-192.168.30.100}

echo "[*] Création du container LXC $CONTAINER_NAME avec IP $CONTAINER_IP..."

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
    
# Vérification de la création du conteneur
if [ $? -ne 0 ]; then
    echo "Échec de la création du conteneur LXC (ID: $CONTAINER_ID). Arrêt du script."
    exit 1
else
    echo "Conteneur LXC (ID: $CONTAINER_ID) créé avec succès."
fi

echo "[*] Installation de PowerDNS Recursor dans le container..."

pct exec $CONTAINER_ID -- bash -c "apt update && apt install pdns-recursor -y"

echo "[*] Configuration de pdns.conf..."

pct exec $CONTAINER_ID -- bash -c "
RECURSOR_CONF='/etc/powerdns/recursor.conf'
cp \$RECURSOR_CONF \$RECURSOR_CONF.bak

echo 'local-port=53' >> \$RECURSOR_CONF
echo "forward-zones=${YOUR_DOMAIN}=${DNS_AUTH_IP}" >> \$RECURSOR_CONF
echo 'local-address=0.0.0.0' >> \$RECURSOR_CONF
echo 'allow-from=0.0.0.0/0' >> \$RECURSOR_CONF
"


pct exec $CONTAINER_ID -- systemctl disable systemd-resolved.service
pct exec $CONTAINER_ID -- systemctl stop systemd-resolved.service
pct exec $CONTAINER_ID -- systemctl restart pdns-recursor
pct exec $CONTAINER_ID -- systemctl enable pdns-recursor


echo "[✓] PowerDNS Recursor est maintenant installé"
