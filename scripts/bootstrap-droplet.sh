#!/usr/bin/env bash
# bootstrap-droplet.sh — Esegui UNA SOLA VOLTA su un droplet Ubuntu 24.04 nuovo.
# Installa Docker, configura UFW, crea l'utente dit e prepara la cartella deploy.
# Lancialo come root via SSH:
#   ssh root@<DROPLET_IP> "bash -s" < scripts/bootstrap-droplet.sh
set -euo pipefail

# Evita prompt interattivi durante apt-get
export DEBIAN_FRONTEND=noninteractive
export NEEDRESTART_MODE=a
export NEEDRESTART_SUSPEND=1

echo "==> 1/6 Aggiornamento sistema"
apt-get update -y
apt-get -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold" upgrade -y

echo "==> 2/6 Installazione pacchetti base"
apt-get install -y ca-certificates curl gnupg ufw git fail2ban

echo "==> 3/6 Installazione Docker Engine"
install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
    | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
chmod a+r /etc/apt/keyrings/docker.gpg
echo \
  "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
  https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo "$VERSION_CODENAME") stable" \
  > /etc/apt/sources.list.d/docker.list
apt-get update -y
apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
systemctl enable --now docker

echo "==> 4/6 Configurazione firewall (UFW)"
ufw --force reset
ufw default deny incoming
ufw default allow outgoing
ufw allow OpenSSH
ufw allow 80/tcp
ufw allow 443/tcp
ufw allow 443/udp
ufw --force enable

echo "==> 5/6 Creazione utente 'dit' (deploy non-root)"
if ! id dit >/dev/null 2>&1; then
    adduser --disabled-password --gecos "" dit
    usermod -aG docker dit
    mkdir -p /home/dit/.ssh
    if [ -f /root/.ssh/authorized_keys ]; then
        cp /root/.ssh/authorized_keys /home/dit/.ssh/authorized_keys
        chown -R dit:dit /home/dit/.ssh
        chmod 700 /home/dit/.ssh
        chmod 600 /home/dit/.ssh/authorized_keys
    fi
fi

echo "==> 6/6 Predisposizione cartella /opt/dit"
mkdir -p /opt/dit
chown dit:dit /opt/dit

echo
echo "Bootstrap completato. Prossimi step:"
echo "  ssh dit@<DROPLET_IP>"
echo "  git clone <dit-infra-repo> /opt/dit"
echo "  cd /opt/dit && cp .env.prod.example .env.prod && nano .env.prod"
echo "  echo \$GITHUB_PAT | docker login ghcr.io -u <user> --password-stdin"
echo "  docker compose -f docker-compose.prod.yml --env-file .env.prod pull"
echo "  ./scripts/migrate.sh"
echo "  docker compose -f docker-compose.prod.yml --env-file .env.prod up -d"
