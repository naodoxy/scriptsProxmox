#!/bin/bash

[ -f /tmp/.network_env ] && source /tmp/.network_env

# Vérification que le script est exécuté en root
if [ "$EUID" -ne 0 ]; then
    echo "Ce script doit être exécuté en tant que root."
    exit 1
fi

# Questions à l'utilisateur
read -p "Quel ID souhaitez-vous pour le container LXC ? [100] : " CONTAINER_ID
CONTAINER_ID=${CONTAINER_ID:-100}

read -p "Quel est le nom de votre container ? [dnsAuth] : " CONTAINER_NAME
CONTAINER_NAME=${CONTAINER_NAME:-dnsAuth}

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

while true; do
    read -s -p "Quel mot de passe voulez vous pour votre base de donnée?: " PDNS_DB_PASSWORD
    echo
    read -s -p "Confirmez le mot de passe : " PASSWORD_CONFIRM
    echo
    if [ "$PDNS_DB_PASSWORD" = "$PASSWORD_CONFIRM" ]; then
        break
    else
        echo "❌ Les mots de passe ne correspondent pas. Veuillez réessayer."
    fi
done

read -p "Entrez la clé API pour PowerDNS ADMIN: " PDNS_API_KEY
PDNS_API_KEY=${PDNS_API_KEY}

read -p "Sur quel port voulez vous accéder à PowerDNS Admin? [9595]: " D_PORT
D_PORT=${D_PORT:-9595}

read -p "Entrez l'IP du serveur principal [10.1.1.15]: " SERVER_IP
SERVER_IP=${SERVER_IP:-10.1.1.15}

read -p "Entrez le nom de votre zone/domaine [int.com]: " ZONE_NAME
ZONE_NAME=${ZONE_NAME:-int.com}

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

echo "[*] Installation de PowerDNS dans le container..."

pct exec $CONTAINER_ID -- bash -c "apt update && apt install -y pdns-server pdns-backend-mysql mariadb-server mariadb-client"

echo "[*] Configuration de MariaDB..."

pct exec $CONTAINER_ID -- bash -c "mysql -u root -e \"
CREATE DATABASE powerdns;
CREATE USER 'powerdns'@'localhost' IDENTIFIED BY '$PDNS_DB_PASSWORD';
GRANT ALL PRIVILEGES ON powerdns.* TO 'powerdns'@'localhost';
FLUSH PRIVILEGES;
\""

pct exec $CONTAINER_ID -- bash -c "mysql -u powerdns -p$PDNS_DB_PASSWORD powerdns < /usr/share/pdns-backend-mysql/schema/schema.mysql.sql"

echo "[*] Création de la zone DNS dans PowerDNS..."
pct exec $CONTAINER_ID -- bash -c "mysql -u powerdns -p$PDNS_DB_PASSWORD powerdns -e \
\"INSERT INTO domains (name, type) VALUES ('$ZONE_NAME', 'NATIVE');\""


pct exec $CONTAINER_ID -- bash -c "mysql -u powerdns -p$PDNS_DB_PASSWORD powerdns -e \"
INSERT INTO records (domain_id, name, type, content, ttl, prio, disabled)
VALUES
  (
    (SELECT id FROM domains WHERE name = '$ZONE_NAME'),
    '$ZONE_NAME',
    'SOA',
    'ns1.$ZONE_NAME. admin.$ZONE_NAME. 1 3600 1800 604800 86400',
    3600,
    NULL,
    0
  ),
  (
    (SELECT id FROM domains WHERE name = '$ZONE_NAME'),
    '$ZONE_NAME',
    'NS',
    'ns1.$ZONE_NAME.',
    3600,
    NULL,
    0
  );\""

pct exec $CONTAINER_ID -- bash -c "mysql -u powerdns -p$PDNS_DB_PASSWORD powerdns -e \"
INSERT INTO records (domain_id, name, type, content, ttl, prio, disabled)
VALUES (
  (SELECT id FROM domains WHERE name = '$ZONE_NAME'),
  'ns1.$ZONE_NAME',
  'A',
  '$SERVER_IP',
  3600,
  NULL,
  0
);\""


echo "[*] Configuration de pdns.conf..."

pct exec $CONTAINER_ID -- bash -c "echo '
launch=gmysql
gmysql-host=127.0.0.1
gmysql-user=powerdns
gmysql-password=$PDNS_DB_PASSWORD
gmysql-dbname=powerdns
' >> /etc/powerdns/pdns.conf"

echo "[*] Désactivation de systemd-resolved et redémarrage de PowerDNS..."

pct exec $CONTAINER_ID -- systemctl disable systemd-resolved.service
pct exec $CONTAINER_ID -- systemctl stop systemd-resolved.service
pct exec $CONTAINER_ID -- systemctl restart pdns.service

echo "[✓] Installation terminée pour $CONTAINER_NAME sur $CONTAINER_IP"


echo "[*] Création de la zone DNS dans PowerDNS..."
pct exec $CONTAINER_ID -- bash -c "mysql -u powerdns -p$PDNS_DB_PASSWORD powerdns -e \
\"INSERT INTO domains (name, type) VALUES ('$ZONE_NAME', 'NATIVE');\""


echo "[*] Installation de PowerDNS-Admin dans le container..."

pct exec $CONTAINER_ID -- bash -c "
apt update && apt install -y \
    git python3-virtualenv build-essential pkg-config libmariadb-dev libssl-dev \
    libxmlsec1-dev libxml2-dev libxmlsec1-openssl libldap2-dev libsasl2-dev \
    libpq-dev nginx python3-dev python3-venv libxslt1-dev libffi-dev \
    apt-transport-https virtualenv python3-flask curl gnupg

curl -sL https://deb.nodesource.com/setup_20.x | bash -
apt-get install -y nodejs

wget -O- https://dl.yarnpkg.com/debian/pubkey.gpg | gpg --dearmor > /etc/apt/trusted.gpg.d/yarnpkg.gpg
echo 'deb https://dl.yarnpkg.com/debian/ stable main' > /etc/apt/sources.list.d/yarn.list
apt update && apt install -y yarn

# Activer l'API dans PowerDNS
sed -i '/^# api=/c\\api=yes' /etc/powerdns/pdns.conf
sed -i \"/^# api-key=/c\\api-key=$PDNS_API_KEY\" /etc/powerdns/pdns.conf
sed -i '/^# webserver=/c\\webserver=yes' /etc/powerdns/pdns.conf
sed -i '/^# webserver-allow-from=/c\\webserver-allow-from=127.0.0.1,192.168.30.0/24' /etc/powerdns/pdns.conf
sed -i '/^# webserver-port=/c\\webserver-port=8081' /etc/powerdns/pdns.conf
systemctl restart pdns.service

# Installer PowerDNS-Admin
git clone https://github.com/PowerDNS-Admin/PowerDNS-Admin.git /var/www/html/pdns
cd /var/www/html/pdns
virtualenv -p python3 flask
source ./flask/bin/activate
sed -i 's/PyYAML==5.4/PyYAML==6.0/g' requirements.txt
pip install --upgrade pip
pip install -r requirements.txt
deactivate

# Configurer le fichier production.py
cp configs/development.py configs/production.py
sed -i \"/^# import urllib.parse/c\\import urllib.parse\" configs/production.py
sed -i \"/^SQLA_DB_USER/c\\SQLA_DB_USER = 'powerdns'\" configs/production.py
sed -i \"/^SQLA_DB_PASSWORD/c\\SQLA_DB_PASSWORD = '$PDNS_DB_PASSWORD'\" configs/production.py
sed -i \"/^SQLA_DB_HOST/c\\SQLA_DB_HOST = '127.0.0.1'\" configs/production.py
sed -i \"/^SQLA_DB_NAME/c\\SQLA_DB_NAME = 'powerdns'\" configs/production.py
echo \"SQLALCHEMY_DATABASE_URI = 'mysql://powerdns:$PDNS_DB_PASSWORD@127.0.0.1/powerdns'\" >> configs/production.py
sed -i \"/^# SECRET_KEY =/c\\SECRET_KEY = '$PDNS_API_KEY'\" configs/production.py
sed -i \"/^FILESYSTEM_SESSIONS_ENABLED/c\\FILESYSTEM_SESSIONS_ENABLED = True\" configs/production.py

# Base de données et assets
source ./flask/bin/activate
export FLASK_APP=powerdnsadmin/__init__.py
export FLASK_CONF=../configs/production.py
flask db upgrade
yarn install --pure-lockfile --ignore-scripts
flask assets build
deactivate

# Créer utilisateur pdns
useradd -r -s /bin/false pdns
mkdir -p /run/pdnsadmin
chown -R pdns:www-data /var/www/html/pdns
chown -R pdns:pdns /run/pdnsadmin
"

echo "[*] Configuration du service systemd et nginx dans le container..."

pct exec $CONTAINER_ID -- bash -c 'cat > /etc/systemd/system/pdnsadmin.service <<EOF
[Unit]
Description=PowerDNS-Admin
Requires=pdnsadmin.socket
After=network.target

[Service]
PIDFile=/run/pdnsadmin/pid
User=pdns
Group=pdns
Environment="FLASK_CONF=../configs/production.py"
WorkingDirectory=/var/www/html/pdns
ExecStart=/var/www/html/pdns/flask/bin/gunicorn --pid /run/pdnsadmin/pid --bind unix:/run/pdnsadmin/socket '\''powerdnsadmin:create_app()'\''
ExecReload=/bin/kill -s HUP \$MAINPID
ExecStop=/bin/kill -s TERM \$MAINPID
PrivateTmp=true

[Install]
WantedBy=multi-user.target
EOF'

pct exec $CONTAINER_ID -- bash -c 'cat > /etc/systemd/system/pdnsadmin.socket <<EOF
[Unit]
Description=PowerDNS-Admin socket

[Socket]
ListenStream=/run/pdnsadmin/socket

[Install]
WantedBy=sockets.target
EOF'

pct exec $CONTAINER_ID -- bash -c 'cat >> /etc/nginx/sites-enabled/powerdns-admin.conf <<EOF
server {
    listen 80;
    server_name _;

    index       index.html index.htm index.php;
    root        /var/www/html/pdns;

    access_log  /var/log/nginx/pdnsadmin_access.log combined;
    error_log   /var/log/nginx/pdnsadmin_error.log;

    client_max_body_size           10m;
    client_body_buffer_size        128k;
    proxy_redirect                 off;
    proxy_connect_timeout          90;
    proxy_send_timeout             90;
    proxy_read_timeout             90;
    proxy_buffers                  32 4k;
    proxy_buffer_size              8k;
    proxy_set_header               Host \$host;
    proxy_set_header               X-Real-IP \$remote_addr;
    proxy_set_header               X-Forwarded-For \$proxy_add_x_forwarded_for;
    proxy_headers_hash_bucket_size 64;

    location ~ ^/static/ {
        include /etc/nginx/mime.types;
        root /var/www/html/pdns/powerdnsadmin;

        location ~* \.(jpg|jpeg|png|gif)$ {
            expires 365d;
        }

        location ~* ^.+\.(css|js)$ {
            expires 7d;
        }
    }

    location / {
        proxy_pass            http://unix:/run/pdnsadmin/socket;
        proxy_read_timeout    120;
        proxy_connect_timeout 120;
        proxy_redirect        off;
    }
}
EOF'

pct exec $CONTAINER_ID -- bash -c "rm -f /etc/nginx/sites-enabled/default && systemctl restart nginx &&  nginx -t && systemctl daemon-reexec && systemctl daemon-reload && systemctl enable --now pdnsadmin.service"

# Règles NAT
iptables -t nat -A PREROUTING -i vmbr0 -p tcp -d $SERVER1_IP --dport $D_PORT -j DNAT --to-destination $CONTAINER_IP:80
iptables -t nat -A POSTROUTING -s $CONTAINER_IP -o vmbr0 -j MASQUERADE
iptables -t nat -A PREROUTING -p udp -d $SERVER1_IP --dport 53 -j DNAT --to-destination $CONTAINER_IP:53
iptables-save > /etc/iptables/rules.v4	

echo "[✓] PowerDNS-Admin est maintenant installé et accessible sur http://$SERVER_IP:$D_PORT"
