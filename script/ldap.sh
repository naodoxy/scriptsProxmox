#!/bin/bash

[ -f /tmp/.network_env ] && source /tmp/.network_env

#Fonction de vérification du format des IP

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
read -p "Quel ID souhaitez-vous pour le container LXC ? [106] : " CONTAINER_ID
CONTAINER_ID=${CONTAINER_ID:-106}

read -p "Quel est le nom de votre container ? [LDAP] : " CONTAINER_NAME
CONTAINER_NAME=${CONTAINER_NAME:-LDAP}

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
    read -s -p "Quel mot de passe voulez vous pour l'admin LDAP?: " ADMIN_PASSWORD
    echo
    read -s -p "Confirmez le mot de passe : " PASSWORD_CONFIRM
    echo
    if [ "$ADMIN_PASSWORD" = "$PASSWORD_CONFIRM" ]; then
        break
    else
        echo "❌ Les mots de passe ne correspondent pas. Veuillez réessayer."
    fi
done

read -s -p "Entrez le mot de passe de la base de données de votre DNS: " MYSQL_ROOT_PASSWORD
echo

read -p "Entrez l'ID du container DNS [100]: " DNS_ID
DNS_ID=${DNS_ID:-100}

read -p "Entrez l'ID du container Traefik [102]: " TRAEFIK_ID
TRAEFIK_ID=${TRAEFIK_ID:-102}

read -p "Quel est le nom de votre organisation? [ex: LDAP]: " ORGANISATION
ORGANISATION=${ORGANISATION:-LDAP}

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

read -p "Entrez le nom de votre zone/domaine [int.com]: " ZONE_NAME
ZONE_NAME=${ZONE_NAME:-int.com}

# Générer automatiquement DOMAIN_NAME à partir de ZONE_NAME
IFS='.' read -ra parts <<< "$ZONE_NAME"
DOMAIN_NAME=""
for part in "${parts[@]}"; do
    DOMAIN_NAME+="dc=$part,"
done
# Retirer la virgule finale
DOMAIN_NAME=${DOMAIN_NAME%,}


read -p "Entrez le nom de votre zone/domaine [int.com]: " zone
zone=${zone:-int.com}  # valeur par défaut si vide

# Convertir en format dc=xxx,dc=yyy
IFS='.' read -ra parts <<< "$zone"
dc=""
for part in "${parts[@]}"; do
    dc+="dc=$part,"
done
# Retirer la virgule finale
dc=${dc%,}

echo "Zone : $zone"
echo "Zone en format LDAP : $dc"

cat <<EOF >> infra_conf.txt

Configuration de Gitea:

Nom du conteneur: $CONTAINER_NAME
ID du conteneur: $CONTAINER_ID
IP du conteneur: $CONTAINER_IP
Gateway du conteneur: $LXC_GATEWAY
Nom de domaine sous forme dc (pour LDAP): DOMAIN_NAME
EOF

echo "[*] Création du container LXC $CONTAINER_NAME avec IP $CONTAINER_IP..."

# Création du container LXC basique sous Debian 
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

pct exec $CONTAINER_ID -- bash -c "apt-get update && apt-get install -y locales"
pct exec $CONTAINER_ID -- bash -c "locale-gen en_US.UTF-8"
pct exec $CONTAINER_ID -- bash -c "update-locale LANG=en_US.UTF-8"

echo "[*] Installation de LDAP dans le container..."

# Preseed debconf for slapd
pct exec $CONTAINER_ID -- bash -c "echo 'slapd slapd/internal/adminpw password $ADMIN_PASSWORD' | debconf-set-selections"
pct exec $CONTAINER_ID -- bash -c "echo 'slapd slapd/internal/generated_adminpw password $ADMIN_PASSWORD' | debconf-set-selections"
pct exec $CONTAINER_ID -- bash -c "echo 'slapd slapd/password1 password $ADMIN_PASSWORD' | debconf-set-selections"
pct exec $CONTAINER_ID -- bash -c "echo 'slapd slapd/password2 password $ADMIN_PASSWORD' | debconf-set-selections"
pct exec $CONTAINER_ID -- bash -c "echo 'slapd slapd/domain string $ZONE_NAME' | debconf-set-selections"
pct exec $CONTAINER_ID -- bash -c "echo 'slapd shared/organization string $ORGANISATION' | debconf-set-selections"
pct exec $CONTAINER_ID -- bash -c "echo 'slapd slapd/backend select HDB' | debconf-set-selections"
pct exec $CONTAINER_ID -- bash -c "echo 'slapd slapd/purge_database boolean true' | debconf-set-selections"
pct exec $CONTAINER_ID -- bash -c "echo 'slapd slapd/move_old_database boolean true' | debconf-set-selections"
pct exec $CONTAINER_ID -- bash -c "echo 'slapd slapd/allow_ldap_v2 boolean false' | debconf-set-selections"
pct exec $CONTAINER_ID -- bash -c "echo 'slapd slapd/no_configuration boolean false' | debconf-set-selections"

# Installer LDAP
pct exec $CONTAINER_ID -- bash -c "DEBIAN_FRONTEND=noninteractive apt-get update && apt-get install -y slapd ldap-utils nfs-common nfs-kernel-server"

echo "LDAP installé"

# Run dpkg-reconfigure (noninteractive)
pct exec $CONTAINER_ID -- bash -c "DEBIAN_FRONTEND=noninteractive dpkg-reconfigure slapd"

echo "LDAP reconfiguré"

echo "[*] Mise à jour du mot de passe admin LDAP dans la configuration..."

# Générer le hash du mot de passe admin LDAP
ADMIN_HASH=$(pct exec $CONTAINER_ID -- slappasswd -s "$ADMIN_PASSWORD")

# Créer le fichier ldif pour modifier olcRootPW
pct exec $CONTAINER_ID -- bash -c "cat > /tmp/modpw.ldif <<EOF
dn: olcDatabase={1}mdb,cn=config
changetype: modify
replace: olcRootPW
olcRootPW: $ADMIN_HASH
EOF"

# Appliquer la modification via ldapmodify
pct exec $CONTAINER_ID -- ldapmodify -Y EXTERNAL -H ldapi:/// -f /tmp/modpw.ldif

echo "[✓] Mot de passe admin LDAP mis à jour avec succès."


# Ajout des schémas
for schema in core cosine inetorgperson nis; do
  pct exec $CONTAINER_ID -- ldapadd -Y EXTERNAL -H ldapi:/// -f /etc/ldap/schema/$schema.ldif
done

echo "Ajout OUs"

pct exec $CONTAINER_ID -- bash -c "cat > base.ldif <<EOF
dn: ou=users,$DOMAIN_NAME
objectClass: organizationalUnit
ou: users

dn: ou=groups,$DOMAIN_NAME
objectClass: organizationalUnit
ou: groups
EOF"

pct exec $CONTAINER_ID -- ldapadd -x -D "cn=admin,$DOMAIN_NAME" -w "$ADMIN_PASSWORD" -f base.ldif

echo "Installation de phpldamadin"

pct exec $CONTAINER_ID -- bash -c "
wget -q https://launchpad.net/ubuntu/+archive/primary/+files/phpldapadmin_1.2.6.3-0.3_all.deb && \
dpkg -i phpldapadmin_1.2.6.3-0.3_all.deb || apt-get install -f -y
"

echo "Fichier conf ldap admin"

pct exec $CONTAINER_ID -- sed -i "s|\\\$servers->setValue('server','base',.*|\\\$servers->setValue('server','base',array('$DOMAIN_NAME'));|" /etc/phpldapadmin/config.php

pct exec $CONTAINER_ID -- sed -i "s|\\\$servers->setValue('login','bind_id',.*|\\\$servers->setValue('login','bind_id','cn=admin,$DOMAIN_NAME');|" /etc/phpldapadmin/config.php

pct exec $CONTAINER_ID -- systemctl restart apache2

echo "Config DNS record"

pct exec $DNS_ID -- bash -c "
mysql -u root -p$MYSQL_ROOT_PASSWORD -e \"
USE powerdns;
INSERT INTO records (domain_id, name, type, content, ttl, prio, disabled)
VALUES (
  (SELECT id FROM domains WHERE name = '$ZONE_NAME'),
  'phpldapadmin.$ZONE_NAME',
  'A',
  '$SERVER_IP',
  3600,
  NULL,
  0
);
\""

pct exec $TRAEFIK_ID -- bash -c "cat > /etc/traefik/dynamic/phpldapadmin.yml << 'EOF'
http:
  routers:
    phpldapadmin-router:
      rule: \"Host(\`phpldapadmin.$ZONE_NAME\`)\"
      entryPoints:
        - web
      service: phpldapadmin-service

  services:
    phpldapadmin-service:
      loadBalancer:
        servers:
          - url: 'http://$CONTAINER_IP:80'
EOF"

pct exec $TRAEFIK_ID -- systemctl restart traefik.service

echo "[✓] LDAP est maintenant installé"
