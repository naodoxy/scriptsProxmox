#!/bin/bash

[ -f /tmp/.network_env ] && source /tmp/.network_env

#Fonction de vérification des IP
is_valid_ip() {
  local ip=$1
  # Vérifie le format global avec regex
  if [[ $ip =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
    # Vérifie que chaque octet est entre 0 et 255
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
read -p "Quel ID souhaitez-vous pour le container LXC ? [105] : " CONTAINER_ID
CONTAINER_ID=${CONTAINER_ID:-105}

read -p "Quel est le nom de votre container ? [bitwarden] : " CONTAINER_NAME
CONTAINER_NAME=${CONTAINER_NAME:-bitwarden}

CONTAINER_IP="${LXC_BASE}.${CONTAINER_ID}"

while true; do
  read -p "Entrez l'IP du serveur proxmox [10.1.1.15]: " SERVER_IP
  SERVER_IP=${SERVER_IP:-10.1.1.15}

  if is_valid_ip "$SERVER_IP"; then
    break
  else
    echo "Erreur : L'adresse IP n'est pas valide. Merci de réessayer."
  fi
done

echo "IP valide : $SERVER_IP"

read -p "Entrez l'ID du container DNS [100]: " DNS_ID
DNS_ID=${DNS_ID:-100}

read -p "Entrez le nom de votre zone/domaine [int.com]: " ZONE_NAME
ZONE_NAME=${ZONE_NAME:-int.com}

read -p "Entrez l'ID du container Traefik [102]: " TRAEFIK_ID
TRAEFIK_ID=${TRAEFIK_ID:-102}


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

read -s -p "Entrez le mot de passe de la base de données de votre DNS: " MYSQL_ROOT_PASSWORD
echo

cat <<EOF >> infra_conf.txt

Configuration de Bitwarden:

Nom du conteneur: $CONTAINER_NAME
ID du conteneur: $CONTAINER_ID
IP du conteneur: $CONTAINER_IP
Gateway du conteneur: $LXC_GATEWAY
EOF

# Création du container LXC basique sous Debian (modifie selon ton template et stockage)
pct create $CONTAINER_ID local:vztmpl/ubuntu-22.04-standard_22.04-1_amd64.tar.zst \
    --hostname $CONTAINER_NAME \
    --cores 2 \
    --memory 2048 \
    --net0 name=eth0,bridge=$LXC_VMBR,ip=${CONTAINER_IP}/${LXC_CIDR},gw=${LXC_GATEWAY} \
    --rootfs local-lvm:15 \
    --password $ROOT_PASSWORD \
    --unprivileged 0 \
    --start 1

# Vérification de la création du conteneur
if [ $? -ne 0 ]; then
    echo "Échec de la création du conteneur LXC (ID: $CONTAINER_ID). Arrêt du script."
    exit 1
else
    echo "Conteneur LXC (ID: $CONTAINER_ID) créé avec succès."
fi


# 🔧 Ajout de la configuration LXC pour permettre Docker
CONF_FILE="/etc/pve/lxc/${CONTAINER_ID}.conf"

cat <<EOF >> "$CONF_FILE"
lxc.apparmor.profile: unconfined
lxc.cap.drop:
lxc.cgroup2.devices.allow: a
lxc.mount.auto: proc sys
lxc.apparmor.allow_nesting: 1
EOF

# Redémarrage du container pour appliquer les changements
pct reboot $CONTAINER_ID


echo "Installation de docker..."

pct exec $CONTAINER_ID -- bash -c "
  apt-get update && apt-get install -y \
    ca-certificates curl gnupg lsb-release

  mkdir -p /etc/apt/keyrings

  curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg

  echo \"deb [arch=\$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu \$(lsb_release -cs) stable\" | tee /etc/apt/sources.list.d/docker.list > /dev/null

  apt-get update

  apt-get install -y docker-ce docker-ce-cli containerd.io
"

pct exec $CONTAINER_ID -- systemctl start docker
pct exec $CONTAINER_ID -- systemctl enable docker

echo "Installation de docker compose..."

pct exec $CONTAINER_ID -- bash -c 'curl -L "https://github.com/docker/compose/releases/latest/download/docker-compose-$(uname -s)-$(uname -m)" -o /usr/local/bin/docker-compose'
pct exec $CONTAINER_ID -- chmod +x /usr/local/bin/docker-compose

echo "Installation de Bitwarden..."

pct exec $CONTAINER_ID -- mkdir -p /root/bitwarden

pct exec $CONTAINER_ID -- bash -c "cd /root/bitwarden && curl -Lso bitwarden.sh https://go.btwrdn.co/bw-sh && chmod +x bitwarden.sh"


pct exec $CONTAINER_ID -- bash -c "cd /root/bitwarden && ./bitwarden.sh install"

pct exec $CONTAINER_ID -- bash -c '
ENV_FILE="/root/bitwarden/bwdata/env/global.override.env"

sed -i "/^globalSettings__mail__/d" "$ENV_FILE"

cat <<EOF >> "$ENV_FILE"
globalSettings__mail__replyToEmail=bitwardenproxmox@gmail.com
globalSettings__mail__smtp__host=smtp.gmail.com
globalSettings__mail__smtp__port=587
globalSettings__mail__smtp__ssl=false
globalSettings__mail__smtp__username=bitwardenproxmox@gmail.com
globalSettings__mail__smtp__password=ixfpmcevicygoktd
globalSettings__mail__smtp__trustServer=true
globalSettings__mail__smtp__startTls=true
EOF
'

echo "✔ SMTP configuré dans le conteneur $CONTAINER_ID"


pct exec $CONTAINER_ID -- bash -c "cd /root/bitwarden/ && ./bitwarden.sh start"

pct exec $DNS_ID -- bash -c "
mysql -u root -p$MYSQL_ROOT_PASSWORD -e \"
USE powerdns;
INSERT INTO records (domain_id, name, type, content, ttl, prio, disabled)
VALUES (
  (SELECT id FROM domains WHERE name = '$ZONE_NAME'),
  'bitwarden.$ZONE_NAME',
  'A',
  '$SERVER_IP',
  3600,
  NULL,
  0
);
\""

pct exec $TRAEFIK_ID -- bash -c "
DOMAIN_NAME=bitwarden.int.com
CERT_DIR=/etc/ssl/bitwarden

mkdir -p \$CERT_DIR

openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
  -keyout \$CERT_DIR/bitwarden.key \
  -out \$CERT_DIR/bitwarden.crt \
  -subj \"/CN=\$DOMAIN_NAME\"

echo 'Certificats générés dans \$CERT_DIR'
"

pct exec $TRAEFIK_ID -- bash -c 'cat <<EOF >> /etc/traefik/traefik.yml
tls:
  certificates:
    - certFile: "/etc/ssl/bitwarden/bitwarden.crt"
      keyFile: "/etc/ssl/bitwarden/bitwarden.key"
EOF
'

echo 'Fichier de configuration TLS généré dans /etc/traefik/dynamic/bitwarden_tls.yml'
"

pct exec $TRAEFIK_ID -- bash -c "cat > /etc/traefik/dynamic/bitwarden.yml << 'EOF'
---
http:
  routers:
    bitwarden-router-http:
      entryPoints:
        - web
      rule: \"Host(\`bitwarden.$ZONE_NAME\`)\"
      middlewares:
        - redirect-to-https
      service: noop@internal

    bitwarden-router-https:
      entryPoints:
        - websecure
      rule: \"Host(\`bitwarden.$ZONE_NAME\`)\"
      tls: {}
      service: bitwarden-service

  middlewares:
    redirect-to-https:
      redirectScheme:
        scheme: https
        permanent: true

  services:
    bitwarden-service:
      loadBalancer:
        servers:
          - url: \"http://$CONTAINER_IP:80\"
EOF"


echo "[✓] Bitwarden est installé"
