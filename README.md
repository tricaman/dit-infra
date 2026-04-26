# dit-infra

Infrastruttura di produzione per i servizi backend di Dit.

Tutto gira in Docker Compose su un singolo droplet DigitalOcean:

| Servizio   | Tipo                | Esposto come                      |
| ---------- | ------------------- | --------------------------------- |
| caddy      | reverse proxy + TLS | `:80`, `:443`                     |
| dit-api    | NestJS REST         | `https://dit-api.mariustrica.com` |
| dit-ping   | Go WebSocket        | `wss://dit-ws.mariustrica.com/ws` |
| dit-worker | BullMQ consumer     | (interno)                         |
| postgres   | PostgreSQL 16       | (interno)                         |
| redis      | Redis 7             | (interno)                         |

> **Routing:**
>
> - `dit-api.mariustrica.com` → `dit-api` (rotte `/auth`, `/users`, `/contacts`, `/pings`, `/docs`, ecc.)
> - `dit-ws.mariustrica.com/ws` → `dit-ping` (WebSocket); `/health` per liveness.

---

## 1. Crea il droplet su DigitalOcean

- **OS**: Ubuntu 24.04 LTS
- **Taglia consigliata iniziale**: `s-2vcpu-2gb` (~$18/mese). Se vuoi tagliare i costi e i volumi sono bassissimi va anche `s-1vcpu-2gb`.
- **Region**: la più vicina ai tuoi utenti (es. `fra1` per l'Italia).
- **Backups**: abilita i backup settimanali di DO (~+20% del costo). Ti danno snapshot automatico dell'intero droplet — utile come secondo livello di backup oltre al `pg_dump`.
- **SSH key**: aggiungi la tua public key durante la creazione, NON la password.
- (Opzionale) Aggiungi un **Reserved IP** per non perdere l'IP se ricrei il droplet.

## 2. Configura il DNS

Dal tuo registrar / DNS provider crea due record A puntati all'IP del droplet:

```
A   dit-api.mariustrica.com   →  <DROPLET_IP>
A   dit-ws.mariustrica.com    →  <DROPLET_IP>
```

Aspetta che la propagazione sia completa prima del primo `up -d` (Caddy proverebbe a richiedere certificati Let's Encrypt e fallirebbe):

```bash
dig +short dit-api.mariustrica.com
dig +short dit-ws.mariustrica.com
```

## 3. Bootstrap del droplet

Da locale, manda lo script di bootstrap come root (la connessione root viene chiusa una volta finito):

```bash
ssh root@<DROPLET_IP> "bash -s" < scripts/bootstrap-droplet.sh
```

Lo script:

1. aggiorna il sistema;
2. installa Docker Engine + Compose plugin;
3. abilita UFW (solo `22`, `80`, `443`);
4. crea l'utente non-root `dit` (eredita la chiave SSH dall'utente `root`);
5. prepara `/opt/dit` come deploy directory.

Da qui in poi connettiti **come `dit`**:

```bash
ssh dit@<DROPLET_IP>
```

## 4. Clona dit-infra sul droplet

```bash
sudo chown -R dit:dit /opt/dit
git clone https://github.com/tricaman/dit-infra.git /opt/dit
# Nota: dit-infra sta sotto user tricaman; i 3 repo applicativi (dit-api, dit-ping,
# dit-notifications-worker) stanno sotto org Tricabit. Le immagini GHCR sono su
# ghcr.io/tricabit/<repo> (lowercase obbligatorio nei path GHCR).
cd /opt/dit
cp .env.prod.example .env.prod
nano .env.prod   # popola tutti i secret — vedi sezione "Variabili obbligatorie"
chmod +x scripts/*.sh
```

### Variabili obbligatorie da generare

```bash
openssl rand -hex 32   # JWT_SECRET (DEVE coincidere fra dit-api e dit-ping)
openssl rand -hex 32   # BETTER_AUTH_SECRET
openssl rand -base64 24 # POSTGRES_PASSWORD
```

`FIREBASE_SERVICE_ACCOUNT_JSON`: prendi il JSON del service account dal Firebase Console e mettilo su una sola riga (i `\n` nella private key vanno mantenuti come stringa letterale `\n`).

### OAuth callback da registrare

Nei provider OAuth registra le seguenti redirect URI (tutte sull'host di dit-api):

- Google: `https://dit-api.mariustrica.com/auth/callback/google`
- Facebook: `https://dit-api.mariustrica.com/auth/callback/facebook`
- Microsoft: `https://dit-api.mariustrica.com/auth/callback/microsoft`

## 5. Login a GHCR (per scaricare le immagini private)

I tre repo applicativi (sotto org `Tricabit`) pushano su GHCR via GitHub Actions (vedi sezione 8). Per scaricarle dal droplet ti serve un Personal Access Token con scope `read:packages`:

1. https://github.com/settings/tokens → "Generate new token (classic)" → scope `read:packages` (e `repo` se i package sono privati).
2. Assicurati che il PAT abbia accesso all'org `Tricabit`: dopo crearlo, vai su https://github.com/settings/tokens, clicca sul token, sezione "Organization access" → "Configure SSO" → autorizza `Tricabit`.
3. Sul droplet:

```bash
echo "<PAT>" | docker login ghcr.io -u tricaman --password-stdin
```

(L'username del login è il tuo user personale `tricaman`; il PAT include i permessi sull'org.)

Il login persiste in `~/.docker/config.json`.

## 6. Primo deploy

```bash
# Pull delle 3 immagini applicative
docker compose -f docker-compose.prod.yml --env-file .env.prod pull

# Migrazioni Prisma (parte postgres + container one-shot dit-api)
./scripts/migrate.sh

# Avvia tutto
docker compose -f docker-compose.prod.yml --env-file .env.prod up -d

# Verifica
docker compose -f docker-compose.prod.yml --env-file .env.prod ps
docker compose -f docker-compose.prod.yml --env-file .env.prod logs -f --tail=100 caddy
```

Caddy ottiene automaticamente il certificato Let's Encrypt al primo accesso HTTPS. Apri:

- `https://dit-api.mariustrica.com/docs` → Swagger UI di dit-api
- `https://dit-ws.mariustrica.com/health` → `{"status":"ok"}` di dit-ping

## 7. Deploy successivi

Quando GitHub Actions builda una nuova immagine (su push `main` di uno dei tre repo):

```bash
ssh dit@<DROPLET_IP>
cd /opt/dit
./scripts/deploy.sh
```

`deploy.sh` fa pull, migrate (idempotente) e restart solo dei servizi applicativi (postgres/redis/caddy non vengono toccati).

## 8. CI/CD (in ogni repo applicativo)

Ogni repo (`dit-api`, `dit-ping`, `dit-notifications-worker`) contiene un workflow `.github/workflows/build-and-push.yml` che:

- builda l'immagine Docker su push su `main` o tag `v*`;
- la tagga `latest` + `sha-<short>` + `<version>` (se è un tag);
- la pusha su `ghcr.io/tricabit/<repo-name>` (`github.repository_owner` lowercase = `tricabit`).

Al primo push, vai su https://github.com/orgs/Tricabit/packages, apri ogni package e "Package settings" → "Manage Actions access" verifica che il repo sorgente sia collegato. (Per repo privati il package eredita la visibilità dal repo ma il link va confermato la prima volta.)

> **Nota:** affinché GHCR pubblichi pacchetti privati associati all'utente, dopo il primo push devi rendere il package "linked" al repo e (se vuoi) impostarlo a "private". Vedi: https://docs.github.com/en/packages/learn-github-packages/connecting-a-repository-to-a-package

### (Opzionale) Auto-deploy via webhook

Se vuoi che il droplet faccia auto-deploy ad ogni push, aggiungi nel workflow di ogni repo uno step finale che fa `ssh dit@<DROPLET_IP> '/opt/dit/scripts/deploy.sh'` usando una secret `SSH_DEPLOY_KEY`. Per ora il deploy è manuale.

## 9. Backup PostgreSQL

Schedula un backup giornaliero alle 03:00 UTC:

```bash
crontab -e
```

Aggiungi:

```
0 3 * * * /opt/dit/scripts/backup-postgres.sh >> /var/log/dit-backup.log 2>&1
```

I backup vanno in `/opt/dit/backups/` con rotazione di 14 giorni. Per portarli fuori dal droplet (consigliato), aggiungi uno step `rclone copy` o `aws s3 cp` verso DO Spaces.

### Restore

```bash
gunzip -c backups/dit-<TIMESTAMP>.sql.gz \
  | docker compose -f docker-compose.prod.yml --env-file .env.prod \
      exec -T postgres psql -U "$POSTGRES_USER" -d "$POSTGRES_DB"
```

## 10. Operazioni utili

```bash
# Tail dei log di un servizio
docker compose -f docker-compose.prod.yml --env-file .env.prod logs -f dit-api

# Restart singolo servizio
docker compose -f docker-compose.prod.yml --env-file .env.prod restart dit-ping

# Shell dentro il container API
docker compose -f docker-compose.prod.yml --env-file .env.prod exec dit-api sh

# psql nel postgres
docker compose -f docker-compose.prod.yml --env-file .env.prod exec postgres \
    psql -U "$POSTGRES_USER" -d "$POSTGRES_DB"

# redis-cli
docker compose -f docker-compose.prod.yml --env-file .env.prod exec redis redis-cli
```

## 11. Update dell'app mobile

Nel client mobile imposta:

- `EXPO_PUBLIC_API_URL=https://dit-api.mariustrica.com`
- `EXPO_PUBLIC_WS_URL=wss://dit-ws.mariustrica.com/ws`

(adatta i nomi delle env var Expo in base a come li espone già il client.)
