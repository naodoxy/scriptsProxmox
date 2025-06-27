#!/bin/bash

# Vérification que le script est exécuté en root
if [ "$EUID" -ne 0 ]; then
    echo "Ce script doit être exécuté en tant que root."
    exit 1
fi

# Questions à l'utilisateur
read -p "Quel ID souhaitez-vous pour le container LXC ? [101] : " CONTAINER_ID
CONTAINER_ID=${CONTAINER_ID:-101}

read -p "Quel est le nom de votre container ? [dns-rec] : " CONTAINER_NAME
CONTAINER_NAME=${CONTAINER_NAME:-dns-rec}

read -p "Quelle est l'adresse IP de votre container ? [192.168.30.101] : " CONTAINER_IP
CONTAINER_IP=${CONTAINER_IP:-192.168.30.101}

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
    --net0 name=eth0,bridge=vmbr1,ip=${CONTAINER_IP}/24,gw=192.168.30.254 \
    --rootfs local-lvm:5 \
    --password $ROOT_PASSWORD \
    --unprivileged 1 \
    --start 1


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
