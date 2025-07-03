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
read -p "Quel ID souhaitez-vous pour le container LXC ? [103] : " CONTAINER_ID
CONTAINER_ID=${CONTAINER_ID:-103}

read -p "Quel est le nom de votre container ? [gitea] : " CONTAINER_NAME
CONTAINER_NAME=${CONTAINER_NAME:-gitea}

while true; do
  read -p "Entrez l'IP du serveur proxmox [10.1.1.15]: " SERVER_IP
  SERVER_IP=${SERVER_IP:-10.1.1.15}

  if is_valid_ip "$SERVER_IP"; then
    break
  else
    echo "Erreur : L'adresse IP n'est pas valide. Merci de réessayer."
  fi
done

echo "IP validée : $SERVER_IP"

read -p "Entrez l'ID du container DNS [100]: " DNS_ID
DNS_ID=${DNS_ID:-100}

read -p "Entrez le nom de votre zone/domaine [int.com]: " ZONE_NAME
ZONE_NAME=${ZONE_NAME:-int.com}

read -p "Entrez l'ID du container Traefik [102]: " TRAEFIK_ID
TRAEFIK_ID=${TRAEFIK_ID:-102}

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

while true; do
    read -s -p "Quel mot de passe voulez vous pour votre base de donnée?: " G_DB_PASSWORD
    echo
    read -s -p "Confirmez le mot de passe : " PASSWORD_CONFIRM
    echo
    if [ "$G_DB_PASSWORD" = "$PASSWORD_CONFIRM" ]; then
        break
    else
        echo "❌ Les mots de passe ne correspondent pas. Veuillez réessayer."
    fi
done

read -s -p "Entrez le mot de passe de la base de donnée de votre DNS: " MYSQL_ROOT_PASSWORD
echo

cat <<EOF >> infra_conf.txt

Configuration de Gitea:

Nom du conteneur: $CONTAINER_NAME
ID du conteneur: $CONTAINER_ID
IP du conteneur: $CONTAINER_IP
Gateway du conteneur: $LXC_GATEWAY
EOF

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

echo "[*] Installation de Gitea dans le container..."

pct exec $CONTAINER_ID -- bash -c "apt update && apt install mariadb-server mariadb-client -y"

echo "[*] Configuration de MariaDB..."

pct exec $CONTAINER_ID -- bash -c "mysql -u root -e \"
CREATE DATABASE gitea CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE USER 'gitea'@'localhost' IDENTIFIED BY '$G_DB_PASSWORD';
GRANT ALL PRIVILEGES ON gitea.* TO 'gitea'@'localhost';
FLUSH PRIVILEGES;
EXIT;
\""

pct exec $CONTAINER_ID -- bash -c "apt update && apt install -y git && wget -O /usr/local/bin/gitea https://dl.gitea.com/gitea/1.23.8/gitea-1.23.8-linux-amd64 && chmod +x /usr/local/bin/gitea"

pct exec $CONTAINER_ID -- bash -c "adduser --system --shell /bin/bash --gecos 'Git Version Control' --group --disabled-password --home /home/git git"

pct exec $CONTAINER_ID -- bash -c " mkdir -p /var/lib/gitea/{custom,data,log} && chown -R git:git /var/lib/gitea/ && chmod -R 750 /var/lib/gitea/ && mkdir /etc/gitea && chown root:git /etc/gitea && chmod 770 /etc/gitea"

pct exec $CONTAINER_ID -- bash -c 'cat > /etc/systemd/system/gitea.service <<EOF
[Unit]
Description=Gitea (Git with a cup of tea)
After=network.target

[Service]
Type=simple
User=git
Group=git
WorkingDirectory=/var/lib/gitea
Environment=GITEA_WORK_DIR=/var/lib/gitea
ExecStart=/usr/local/bin/gitea web
Restart=always
RestartSec=5s
LimitNOFILE=65535

[Install]
WantedBy=multi-user.target
EOF'

pct exec $CONTAINER_ID -- bash -c "systemctl start gitea.service && systemctl enable gitea.service"

echo "Ajout de l'entry DNS..."

pct exec $DNS_ID -- bash -c "
mysql -u root -p$MYSQL_ROOT_PASSWORD -e \"
USE powerdns;
INSERT INTO records (domain_id, name, type, content, ttl, prio, disabled)
VALUES (
  (SELECT id FROM domains WHERE name = '$ZONE_NAME'),
  'gitea.$ZONE_NAME',
  'A',
  '$SERVER_IP',
  3600,
  NULL,
  0
);
\""

echo "Ajout du fichier traefik"

pct exec $TRAEFIK_ID -- bash -c "cat > /etc/traefik/dynamic/gitea.yml << 'EOF'
http:
  routers:
    gitea-router:
      rule: \"Host(\`gitea.$ZONE_NAME\`)\"
      entryPoints:
        - web
      service: gitea-service

  services:
    gitea-service:
      loadBalancer:
        servers:
          - url: 'http://$CONTAINER_IP:3000'
EOF"

echo "[✓] Gitea est maintenant installé"
