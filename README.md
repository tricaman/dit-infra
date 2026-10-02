# dit-infra

Infrastruttura di produzione di Dit. Tutto gira in Docker Compose su un singolo droplet DigitalOcean dietro Caddy con TLS automatico Let's Encrypt.

Questo repo contiene **solo** l'orchestrazione (compose, Caddyfile, script). Il codice applicativo vive nei 4 repo separati. Le immagini Docker sono in **GHCR**.

## Indice

- [Architettura](#architettura)
- [Endpoint pubblici](#endpoint-pubblici)
- [Repo correlati](#repo-correlati)
- [Operazioni quotidiane](#operazioni-quotidiane)
- [CI/CD: auto-deploy](#cicd-auto-deploy)
- [Backup & restore PostgreSQL](#backup--restore-postgresql)
- [Setup completo da zero (disaster recovery)](#setup-completo-da-zero-disaster-recovery)
- [Cambio di dominio (cutover)](#cambio-di-dominio-cutover)
- [Variabili `.env.prod`](#variabili-envprod)
- [Troubleshooting / lessons learned](#troubleshooting--lessons-learned)

---

## Architettura

```
                         Internet (TCP 443/80, UDP 443)
                                     │
                                     ▼
                          ┌─────────────────────┐
                          │   Caddy 2-alpine    │ ◄── Let's Encrypt (HTTP-01)
                          │   reverse proxy +   │
                          │   TLS automatico    │
                          └────────┬────────────┘
                                   │
        ┌──────────────────────────┼──────────────────────────┐
        │                          │                          │
        ▼                          ▼                          │
  api.mydit.app             ws.mydit.app/ws                   │
        │                          │                          │
        ▼                          ▼                          │
  ┌──────────┐              ┌──────────┐                      │
  │ dit-api  │              │ dit-ping │                      │
  │ NestJS   │              │ Go WS    │                      │
  │ :3000    │              │ :8080    │                      │
  └─┬──┬───┬─┘              └──┬───┬───┘                      │
    │  │   │                   │   │                          │
    │  │   └───────┬───────────┘   │                          │
    │  │           │               │                          │
    │  │           ▼               │                          │
    │  │     ┌──────────┐          │                          │
    │  │     │  redis   │          │                          │
    │  │     │  pub/sub │          │                          │
    │  │     │  + queue │          │                          │
    │  │     └────┬─────┘          │                          │
    │  │          │                │                          │
    │  │          ▼                │                          │
    │  │    ┌────────────┐         │                          │
    │  │    │ dit-worker │         │                          │
    │  │    │ BullMQ FCM │─────────┼─► Firebase Cloud Messaging
    │  │    └────────────┘         │
    │  │                           │
    │  └───────────┬───────────────┘
    │              ▼
    │       ┌─────────────┐
    └──────►│ postgres 16 │
            │ (volume     │
            │  persistito)│
            └─────────────┘

Network: bridge "dit" (interno) — solo Caddy bind sulle porte pubbliche.
Volumes: pgdata, redis_data, caddy_data, caddy_config (named volumes Docker).
```

### Servizi

| Servizio     | Immagine                                           | Esposizione                    | Volume       |
| ------------ | -------------------------------------------------- | ------------------------------ | ------------ |
| `caddy`      | `caddy:2-alpine`                                   | `:80`, `:443/tcp+udp`          | `caddy_data` |
| `dit-api`    | `ghcr.io/tricaman/dit-api:latest`                  | interno → Caddy                | —            |
| `dit-ping`   | `ghcr.io/tricaman/dit-ping:latest`                 | interno → Caddy (`/ws`)        | —            |
| `dit-worker` | `ghcr.io/tricaman/dit-notifications-worker:latest` | interno (consumer Redis queue) | —            |
| `postgres`   | `postgres:16-alpine`                               | interno                        | `pgdata`     |
| `redis`      | `redis:7-alpine` (`--appendonly yes`)              | interno                        | `redis_data` |

---

## Endpoint pubblici

| URL                                  | Servizio | Note                                   |
| ------------------------------------ | -------- | -------------------------------------- |
| `https://api.mydit.app/`             | dit-api  | Hello world (default NestJS)           |
| `https://api.mydit.app/docs`         | dit-api  | Swagger UI                             |
| `https://api.mydit.app/auth/...`     | dit-api  | BetterAuth (Google OAuth, email + OTP) |
| `https://api.mydit.app/users/...`    | dit-api  | API REST                               |
| `wss://ws.mydit.app/ws`              | dit-ping | WebSocket (auth via JWT shared secret) |

### Host legacy (mariustrica.com)

Prima di `mydit.app` l'infra stava su `dit-api.mariustrica.com` e
`dit-ws.mariustrica.com`. Quei due host **restano serviti** dallo stesso Caddy,
sullo stesso backend: l'URL dell'API è compilata dentro il binario dell'app
(`EXPO_PUBLIC_API_URL` / `EXPO_PUBLIC_WS_URL` in `dit-mobile/eas.json`) e dit
non ha un meccanismo di force-update, quindi ogni installazione anteriore al
cambio continua a chiamare il vecchio host finché l'utente non aggiorna.

Sono configurati via `DOMAIN_API_LEGACY` / `DOMAIN_WS_LEGACY`. Per ritirarli
servono **entrambe** le cose: togliere le variabili (o gli indirizzi dal
`Caddyfile`) **e** i record DNS — non prima che le build che li referenziano
siano fuori uso.

### OAuth callback registrati

- Google: `https://api.mydit.app/auth/callback/google`
- Google (legacy): `https://dit-api.mariustrica.com/auth/callback/google`

**Servono entrambi, contemporaneamente.** Il `baseURL` di BetterAuth non è
fisso: è derivato per richiesta dall'host in arrivo (vedi "Cambio di dominio"),
quindi un login che parte dall'host legacy ci ritorna, e uno che parte dal
dominio nuovo resta sul nuovo. Togliere il redirect vecchio rompe il login
Google di ogni build già installata.

> È il redirect a decidere il dominio mostrato dalla schermata "Scegli un
> account" di Google (`Continua su ...`). Le build nuove leggono `mydit.app`,
> quelle vecchie continuano a leggere `mariustrica.com` — ed è corretto così.

(Facebook e Microsoft non sono implementati lato client, ma le env var sono opzionali e supportabili in futuro senza modifiche backend — basta registrare il provider e settare le credenziali in `.env.prod`.)

---

## Repo correlati

Tutti sotto `github.com/tricaman/`:

- **`dit-infra`** (questo repo) — orchestrazione (compose, Caddyfile, script). Cloned in `/opt/dit` sul droplet.
- **`dit-api`** — NestJS + Prisma + BetterAuth.
- **`dit-ping`** — Go WebSocket hub per ping presence.
- **`dit-notifications-worker`** — BullMQ consumer per push FCM.
- **`dit-mobile`** — client Expo / React Native.

Le immagini GHCR del backend (api/ping/worker) sono **private**. Per pullarle dal droplet serve `docker login ghcr.io -u tricaman` con un PAT scope `read:packages`. Il login è già configurato su `/home/dit/.docker/config.json`.

---

## Operazioni quotidiane

### SSH al droplet

```bash
ssh dit@178.105.228.38
```

L'utente `dit` è non-root, in gruppo `docker`. Tutti i comandi compose vanno lanciati da lui. Per cose di sistema (reboot, apt, ecc.) usa `ssh root@178.105.228.38`.

### Status dei servizi

```bash
cd /opt/dit
docker compose -f docker-compose.prod.yml --env-file .env.prod ps
```

### Tail dei log

```bash
# log live di un servizio
docker compose -f docker-compose.prod.yml --env-file .env.prod logs -f dit-api

# ultimi 100 record di tutti
docker compose -f docker-compose.prod.yml --env-file .env.prod logs --tail=100
```

### Restart manuale di un servizio

```bash
docker compose -f docker-compose.prod.yml --env-file .env.prod restart dit-api
```

### Deploy manuale (full o per singolo servizio)

```bash
cd /opt/dit
./scripts/deploy.sh                # tutto: pull + migrate + restart all
./scripts/deploy.sh dit-api        # solo dit-api + migrate
./scripts/deploy.sh dit-ping       # solo dit-ping
./scripts/deploy.sh dit-worker     # solo dit-worker
```

### Shell dentro un container

```bash
docker compose -f docker-compose.prod.yml --env-file .env.prod exec dit-api sh
docker compose -f docker-compose.prod.yml --env-file .env.prod exec postgres \
    psql -U "$POSTGRES_USER" -d "$POSTGRES_DB"
docker compose -f docker-compose.prod.yml --env-file .env.prod exec redis redis-cli
```

### Aggiornare la config infra (Caddyfile, compose, script)

Il droplet ha un clone di `dit-infra` in `/opt/dit`. Modifica viene **NON** auto-pullata. Quando aggiorni questo repo:

```bash
ssh dit@178.105.228.38
cd /opt/dit
git pull

# Se hai modificato Caddyfile o docker-compose.prod.yml:
docker compose -f docker-compose.prod.yml --env-file .env.prod up -d caddy   # o tutto
```

---

## CI/CD: auto-deploy

Ogni push su `main` di un repo applicativo triggera la pipeline:

```
push main (es. dit-api)
   │
   ├─► Job "build" (~2-3 min)
   │      • docker build via Buildx
   │      • push immagine su ghcr.io/tricaman/<repo>:latest + :sha-<short>
   │      • cache GHA per build più veloci
   │
   └─► Job "deploy" (~30 sec)
          • SSH al droplet con la deploy key (secret SSH_DEPLOY_KEY)
          • lancia: /opt/dit/scripts/deploy.sh <service>
          • lo script fa: docker pull + (se dit-api) migrate Prisma + up -d
          • downtime del singolo servizio: ~5 sec, gli altri non vengono toccati
```

I tag `v*` triggerano solo build (no deploy automatico): comodo per pubblicare release versionate.

### Secret GitHub usati (per ognuno dei 3 repo backend)

| Secret           | Valore                                                             |
| ---------------- | ------------------------------------------------------------------ |
| `SSH_DEPLOY_KEY` | Chiave privata `ed25519` di un keypair dedicato (generato sul Mac) |
| `DROPLET_HOST`   | `178.105.228.38`                                                   |

Il PAT `GITHUB_TOKEN` è automatico (ogni job lo riceve da GitHub Actions per push GHCR).

### Deploy key dettagli

- Tipo: ed25519, dedicato CI (NON la chiave personale).
- File locale: `~/.ssh/dit-gha-deploy` (Mac, gitignored).
- Authorized: `/home/dit/.ssh/authorized_keys` sul droplet.
- Privata salvata anche come secret `SSH_DEPLOY_KEY` su tutti e 3 i repo backend.

Per ruotare la chiave (se compromessa o periodicamente):

```bash
# 1. Genera nuovo keypair
ssh-keygen -t ed25519 -f ~/.ssh/dit-gha-deploy-new -N "" -C "github-actions-deploy@dit"

# 2. Aggiungi public sul droplet, rimuovi vecchia
cat ~/.ssh/dit-gha-deploy-new.pub | ssh dit@178.105.228.38 \
    'cat >> ~/.ssh/authorized_keys'
ssh dit@178.105.228.38 "sed -i '/github-actions-deploy@dit$/d' ~/.ssh/authorized_keys"  # rimuove le vecchie

# 3. Aggiorna SSH_DEPLOY_KEY su ognuno dei 3 repo GitHub:
cat ~/.ssh/dit-gha-deploy-new | pbcopy
# poi paste in https://github.com/tricaman/<repo>/settings/secrets/actions

# 4. Sostituisci il file locale
mv ~/.ssh/dit-gha-deploy-new ~/.ssh/dit-gha-deploy
mv ~/.ssh/dit-gha-deploy-new.pub ~/.ssh/dit-gha-deploy.pub
```

### Rollback rapido a una versione precedente

```bash
ssh dit@178.105.228.38
cd /opt/dit

# Trova lo SHA dell'immagine precedente (cerca nei tag GHCR)
docker pull ghcr.io/tricaman/dit-api:sha-<SHORT_SHA>

# Edita .env.prod per pinnare il tag
nano .env.prod    # imposta DIT_API_TAG=sha-<SHORT_SHA>

# Ricarica
docker compose -f docker-compose.prod.yml --env-file .env.prod up -d dit-api
```

---

## Backup & restore PostgreSQL

### Schedulato

Cron dell'utente `dit` (lanciato giornalmente alle **03:00 UTC**):

```cron
0 3 * * * /opt/dit/scripts/backup-postgres.sh >> /opt/dit/backups/backup.log 2>&1
```

Lo script `scripts/backup-postgres.sh`:

- esegue `pg_dump --format=plain --no-owner --no-privileges` dentro il container postgres;
- comprime con `gzip -9`;
- salva in `/opt/dit/backups/dit-<TIMESTAMP>.sql.gz`;
- ruota: cancella backup più vecchi di **14 giorni**.

### Backup manuale on-demand

```bash
ssh dit@178.105.228.38
/opt/dit/scripts/backup-postgres.sh
```

### Restore

⚠️ **DESTRUTTIVO** — sovrascrive il DB corrente.

```bash
ssh dit@178.105.228.38
cd /opt/dit

# Lista backup disponibili
ls -lh backups/

# Restore da un dump
gunzip -c backups/dit-<TIMESTAMP>.sql.gz \
  | docker compose -f docker-compose.prod.yml --env-file .env.prod \
      exec -T postgres psql -U dit -d dit
```

### Off-site backup (consigliato in futuro)

I backup vivono solo sul droplet. Se il droplet muore senza preavviso, perdi gli ultimi 14 giorni. Per copiarli su DigitalOcean Spaces / S3 / Backblaze:

```bash
# Esempio con rclone (da configurare lato droplet con rclone config)
rclone copy /opt/dit/backups/ remote:dit-backups/ --max-age 25h
```

In alternativa, abilita i **DigitalOcean Backups** del droplet (snapshot settimanali, +20% al costo).

---

## Setup completo da zero (disaster recovery)

> ⚠️ **Questa procedura non ricrea i site block non versionati del Caddyfile.**
> In produzione il file ha in coda blocchi aggiunti a mano per altri progetti
> sullo stesso host (oggi `clash-bot.mariustrica.com`). Prima di ricostruire,
> recuperali dall'ultimo backup del droplet o da `git diff Caddyfile`, e
> ri-appendili dopo il clone. Il dettaglio è commentato nel `Caddyfile`.

Se devi ricreare tutto da zero (droplet bruciato, region cambiata, ecc.):

### 1. Crea il droplet

DigitalOcean → Create Droplet:

- **OS**: Ubuntu 24.04 LTS
- **Plan**: Basic regular SSD, almeno **`s-2vcpu-2gb`** (~$18/mese). Con `s-1vcpu-1gb` siamo molto stretti (~3GB RAM in uso a regime).
- **Region**: vicino agli utenti (es. `fra1`).
- **SSH Key**: la tua chiave personale (Mac).
- **Backups**: opzionale, snapshot settimanali +20%.
- (Opzionale) Reserved IP per non perdere l'IP se ricrei.

Annota l'IP: `<DROPLET_IP>`.

### 2. Configura il DNS

Sul registrar (Keliweb nel nostro caso):

```
A   api.mydit.app   →  <DROPLET_IP>   TTL: 300
A   ws.mydit.app    →  <DROPLET_IP>   TTL: 300
```

Sulla zona `mariustrica.com` restano attivi anche i record storici, che devono
continuare a puntare allo stesso droplet (vedi "Host legacy" sopra):

```
A   dit-api.mariustrica.com   →  <DROPLET_IP>   TTL: 300
A   dit-ws.mariustrica.com    →  <DROPLET_IP>   TTL: 300
```

⚠️ Assicurati che **non** ci siano altri record A duplicati (vecchio IP dimenticato, wildcard `*` inadeguato). Verifica:

```bash
dig @8.8.8.8 +short api.mydit.app
dig @8.8.8.8 +short ws.mydit.app
# Devono restituire SOLO <DROPLET_IP>.
```

Aspetta che la propagazione sia completa **prima** di lanciare i container (Caddy fallirebbe l'emissione del cert Let's Encrypt).

### 3. Bootstrap del droplet

Da Mac, copia lo script e eseguilo come root:

```bash
cd /Users/trica/personal/dit/dit-infra
scp scripts/bootstrap-droplet.sh root@<DROPLET_IP>:/tmp/
ssh root@<DROPLET_IP> "chmod +x /tmp/bootstrap-droplet.sh && /tmp/bootstrap-droplet.sh"
```

Lo script:

1. Aggiorna il sistema (con `DEBIAN_FRONTEND=noninteractive` e `NEEDRESTART_MODE=a` per evitare prompt).
2. Installa Docker Engine + Compose plugin.
3. Abilita UFW (solo `22`, `80`, `443`).
4. Installa fail2ban (anti-brute-force SSH).
5. Crea l'utente non-root `dit` (eredita la chiave SSH dell'utente `root`).
6. Prepara `/opt/dit` come deploy directory di proprietà di `dit:dit`.

### 4. Genera la SSH deploy key per `dit-infra`

Per consentire al droplet di clonare `dit-infra` (privato) senza passare PAT:

```bash
ssh dit@<DROPLET_IP> 'ssh-keygen -t ed25519 -N "" -f ~/.ssh/dit-infra-deploy -C dit-infra-deploy@droplet'
ssh dit@<DROPLET_IP> 'cat ~/.ssh/dit-infra-deploy.pub'
```

Aggiungi la public key come **Deploy Key** (read-only) su https://github.com/tricaman/dit-infra/settings/keys.

Configura SSH alias e clona:

```bash
ssh dit@<DROPLET_IP> 'cat >> ~/.ssh/config << EOF
Host github-dit-infra
  HostName github.com
  User git
  IdentityFile ~/.ssh/dit-infra-deploy
  IdentitiesOnly yes
EOF
chmod 600 ~/.ssh/config
ssh-keyscan -t ed25519 github.com >> ~/.ssh/known_hosts
sort -u ~/.ssh/known_hosts -o ~/.ssh/known_hosts
git clone git@github-dit-infra:tricaman/dit-infra.git /opt/dit'
```

### 5. Crea `.env.prod` sul droplet

```bash
ssh dit@<DROPLET_IP>
cd /opt/dit
cp .env.prod.example .env.prod
chmod 600 .env.prod

# Genera i secret randomici
sed -i "s|^JWT_SECRET=.*|JWT_SECRET=$(openssl rand -hex 32)|" .env.prod
sed -i "s|^BETTER_AUTH_SECRET=.*|BETTER_AUTH_SECRET=$(openssl rand -hex 32)|" .env.prod
sed -i "s|^POSTGRES_PASSWORD=.*|POSTGRES_PASSWORD=$(openssl rand -base64 36 | tr -d '=+/' | head -c 40)|" .env.prod

# Ora apri nano e popola: ACME_EMAIL, BREVO_API_KEY, BREVO_SENDER_EMAIL,
# GOOGLE_CLIENT_ID, GOOGLE_CLIENT_SECRET, FIREBASE_SERVICE_ACCOUNT_JSON
nano .env.prod
chmod +x scripts/*.sh
```

Per `FIREBASE_SERVICE_ACCOUNT_JSON` vedi sezione [Variabili `.env.prod`](#variabili-envprod) — va minified su una sola riga, occhio al quoting.

### 6. Login GHCR sul droplet

Crea un PAT (classic) su https://github.com/settings/tokens con scope `read:packages`. Poi:

```bash
ssh dit@<DROPLET_IP>
docker login ghcr.io -u tricaman      # incolla il PAT come password
```

### 7. Setup deploy key per CI/CD GitHub Actions

Sul Mac:

```bash
ssh-keygen -t ed25519 -f ~/.ssh/dit-gha-deploy -N "" -C "github-actions-deploy@dit"
cat ~/.ssh/dit-gha-deploy.pub | ssh dit@<DROPLET_IP> 'cat >> ~/.ssh/authorized_keys'
cat ~/.ssh/dit-gha-deploy | pbcopy
```

Su GitHub, per **ognuno** dei 3 repo backend (`dit-api`, `dit-ping`, `dit-notifications-worker`) → Settings → Secrets and variables → Actions → New repository secret:

- `SSH_DEPLOY_KEY` → paste della chiave privata (incluse le righe `-----BEGIN/END-----`)
- `DROPLET_HOST` → `<DROPLET_IP>`

### 8. Primo deploy

```bash
ssh dit@<DROPLET_IP>
cd /opt/dit
docker compose -f docker-compose.prod.yml --env-file .env.prod pull
./scripts/migrate.sh
docker compose -f docker-compose.prod.yml --env-file .env.prod up -d
docker compose -f docker-compose.prod.yml --env-file .env.prod ps
```

Caddy emette automaticamente i certificati Let's Encrypt al primo accesso HTTPS. Verifica:

```bash
curl -I https://api.mydit.app/
curl -I https://api.mydit.app/docs
```

### 9. Schedula backup giornaliero

```bash
ssh dit@<DROPLET_IP> '(crontab -l 2>/dev/null; echo "0 3 * * * /opt/dit/scripts/backup-postgres.sh >> /opt/dit/backups/backup.log 2>&1") | crontab -'
```

### 10. (Disaster recovery) Restore del DB da backup off-site

Se hai un backup off-site (es. su DO Spaces / locale Mac):

```bash
# Copia il dump sul droplet
scp dit-2026XXXX.sql.gz dit@<DROPLET_IP>:/opt/dit/backups/

# Restore
ssh dit@<DROPLET_IP>
cd /opt/dit
docker compose -f docker-compose.prod.yml --env-file .env.prod up -d postgres
gunzip -c backups/dit-2026XXXX.sql.gz \
  | docker compose -f docker-compose.prod.yml --env-file .env.prod \
      exec -T postgres psql -U dit -d dit
```

---

## Cambio di dominio (cutover)

Runbook della migrazione `mariustrica.com` → `mydit.app` (agosto 2026). Vale
per qualsiasi cambio futuro dei sottodomini.

### Il vincolo che detta l'ordine

Servire i vecchi host da Caddy copre REST e WebSocket delle build già
pubblicate, ma **non basta per il login Google**.

BetterAuth costruisce il `redirect_uri` dal proprio `baseURL`, mentre il cookie
firmato `state` viene scritto sull'host che **avvia** il flusso — e
`crossSubDomainCookies` è disattivato. Con un `baseURL` fisso puntato al
dominio nuovo, una build vecchia parte da `dit-api.mariustrica.com`, Google la
rimanda su `api.mydit.app/auth/callback/google`, il cookie non c'è, e il login
muore con `state_security_mismatch`.

La soluzione **non** è spostare `BETTER_AUTH_URL`: è toglierlo. Senza
`baseURL` statico BetterAuth lo ricalcola a ogni richiesta dall'host in arrivo
(`better-auth/dist/auth/base.mjs`, ramo `if (!ctx.options.baseURL)`), e
`dispatchToBetterAuth` in `auth.controller.ts` gli passa già l'host reale. Ogni
flusso resta coerente sul proprio dominio: le build vecchie si comportano
esattamente come prima, le nuove vedono `mydit.app`.

### 1. DNS e Caddy in doppio host (additivo)

```
A   api.mydit.app   →  <DROPLET_IP>   TTL: 300   proxy: OFF
A   ws.mydit.app    →  <DROPLET_IP>   TTL: 300   proxy: OFF
```

⚠️ **La zona `mydit.app` è su Cloudflare** (`mariustrica.com` è su Keliweb), e
Cloudflare crea i record nuovi **proxati** per default — nuvola arancione. Vanno
messi su **DNS only**, nuvola grigia, come i record storici.

Col proxy attivo il TLS termina su Cloudflare e non su Caddy: il certificato
Let's Encrypt che Caddy emette non lo vede nessuno, e il WebSocket passa per un
hop in più con un idle timeout suo (~100s), sulla componente da cui dipende
tutto il realtime. Finché Caddy non serve quel nome, un host proxato risponde
`HTTP 525` — è il sintomo con cui si riconosce.

```bash
# nessun header cloudflare = proxy off, come dev'essere
curl -sI https://ws.mydit.app/health | grep -i "^server\|^cf-ray"
```

I record storici su `mariustrica.com` restano dove sono.

Sul droplet l'ordine conta, per due motivi che non si vedono:

**`git pull` PRIMA di toccare `DOMAIN_API`.** Il compose vecchio deriva
`BETTER_AUTH_URL: https://${DOMAIN_API}`. Cambiare `DOMAIN_API` senza aver
prima aggiornato il compose significa che al successivo restart dit-api si
ritrova una base URL *fissa* sul dominio nuovo — cioè esattamente lo scenario
che rompe il login Google delle build già installate.

**Poi fissa `BETTER_AUTH_URL` esplicitamente**, al valore che ha oggi. Col
compose nuovo la variabile arriva da `.env.prod`, e lasciarla vuota attiva la
derivazione per richiesta al primo restart di dit-api — che avviene da solo al
prossimo push su `dit-api`. Fissandola, l'attivazione resta una decisione da
prendere al passo 3, non un effetto collaterale.

```bash
cd /opt/dit && git pull
```

In `.env.prod`:

```
DOMAIN_API=api.mydit.app
DOMAIN_WS=ws.mydit.app
DOMAIN_API_LEGACY=dit-api.mariustrica.com
DOMAIN_WS_LEGACY=dit-ws.mariustrica.com
TRUSTED_ORIGINS=dit://,https://api.mydit.app,https://dit-api.mariustrica.com
BETTER_AUTH_URL=https://dit-api.mariustrica.com   # pin temporaneo, si svuota al passo 3
```

Valida il Caddyfile prima di applicarlo — `run --rm` non pubblica le porte,
quindi non tocca il Caddy in esecuzione:

```bash
docker compose -f docker-compose.prod.yml --env-file .env.prod \
  run --rm --entrypoint caddy caddy validate \
  --config /etc/caddy/Caddyfile --adapter caddyfile
docker compose -f docker-compose.prod.yml --env-file .env.prod up -d caddy
```

Solo `caddy`: dit-api resta com'è. Da qui i due domini nuovi servono REST e
WebSocket in parallelo ai vecchi, e nulla è cambiato per nessuno.

```bash
for h in api.mydit.app dit-api.mariustrica.com; do
  echo -n "$h  "; curl -s -o /dev/null -w "%{http_code}\n" "https://$h/auth/me"
done   # 401 su entrambi
```

### 2. Console Google (additivo)

Aggiungi il redirect URI del dominio nuovo **senza togliere quello vecchio**, e
`mydit.app` fra gli authorized domains. Va fatto prima del passo 3: appena
l'API inizia a mandare Google sul callback nuovo, quel redirect dev'essere già
registrato, o è `redirect_uri_mismatch` per tutti.

### 3. dit-api: `baseURL` per richiesta

Cinque modifiche. Le prime quattro nel codice, la quinta qui — e senza la
quinta le altre non hanno effetto, perché `getBaseURL` legge comunque
`BETTER_AUTH_URL` dall'ambiente.

| File | Modifica |
| ---- | -------- |
| `config.module.ts` | `BETTER_AUTH_URL: z.url()` → `.optional()`, altrimenti il boot fallisce la validazione |
| `betterauth.ts` | `baseURL: process.env['BETTER_AUTH_URL'] \|\| undefined` — il fallback `?? 'http://localhost:3000'` è truthy e disattiverebbe la derivazione |
| `auth.controller.ts:141` e `:375` | `??` → `\|\|`: con la variabile a stringa vuota `??` non ricade su `getRequestBase()` e `new URL()` lancia |
| `docker-compose.prod.yml` | `BETTER_AUTH_URL: ${BETTER_AUTH_URL:-}` al posto di `https://${DOMAIN_API}` |

Il codice è arrivato in produzione col push, ma **inerte**: finché
`BETTER_AUTH_URL` è valorizzata, BetterAuth usa quella e si comporta come
prima. L'attivazione è svuotare il pin messo al passo 1:

```bash
# in .env.prod: BETTER_AUTH_URL=
docker compose -f docker-compose.prod.yml --env-file .env.prod \
  up -d --no-deps --force-recreate dit-api
```

### 4. Cancello: login Google verificato su entrambi gli host

Login Google reale, end-to-end, **due volte**: una da una build che punta
all'host legacy, una da una che punta al dominio nuovo. Entrambe devono
arrivare al deep link con `session_token`.

Se fallisce quella legacy, la regressione colpisce gli utenti già installati.
**Rollback immediato**, senza toccare il codice: rimetti
`BETTER_AUTH_URL=https://dit-api.mariustrica.com` in `.env.prod` e riavvia
`dit-api`. Il valore esplicito ha la precedenza sulla derivazione e tutto torna
come prima.

### 5. dit-admin e mobile

`PUBLIC_API_BASE_URL` nelle env di Vercel, poi redeploy. Gli admin già loggati
rifanno login una volta: la sessione browser è un cookie sull'origine dell'API,
ed è cambiata.

Le build mobile vanno fatte **solo dopo il cancello**: `eas.json` punta già ai
domini nuovi, e pubblicare prima significherebbe rilasciare una versione il cui
login non è ancora stato verificato.

### Cosa non si rompe

- **Le sessioni mobile.** L'app non usa il cookie jar di piattaforma: persiste
  il session token e lo rigioca come header `Cookie` su qualsiasi host
  (`dit-mobile/src/services/api.ts`). Nessuno viene sloggato.
- **Le build già pubblicate**, comprese quelle in revisione sugli store:
  parlano con l'host legacy, che dopo il passo 3 si comporta identico a prima.
- **Il bundle id.** `com.mariustrica.dit` è la chiave delle app pubblicate
  sugli store: non segue il dominio, e non è visibile all'utente da nessuna
  parte.

### Da non fare

- Togliere i record DNS su `mariustrica.com`, o gli host legacy dal `Caddyfile`.
- Rimuovere il vecchio redirect URI dalla console Google.
- Reimpostare `BETTER_AUTH_URL` a un valore fisso dopo il passo 3, se non come
  rollback voluto.

---

## Variabili `.env.prod`

Tutte le variabili sono in `.env.prod.example` con commenti. Ricapitolo per categoria:

### Domini & TLS

| Variabile           | Esempio                   | Note                                        |
| ------------------- | ------------------------- | ------------------------------------------- |
| `DOMAIN_API`        | `api.mydit.app`           | Caddy emette TLS automatica                 |
| `DOMAIN_WS`         | `ws.mydit.app`            | idem                                        |
| `DOMAIN_API_LEGACY` | `dit-api.mariustrica.com` | Host storico, stesso backend — vedi sopra   |
| `DOMAIN_WS_LEGACY`  | `dit-ws.mariustrica.com`  | idem                                        |
| `ACME_EMAIL`        | `you@mydit.app`           | Avvisi Let's Encrypt. **Una casella letta davvero**: è l'unico allarme su un rinnovo fallito |

### GHCR

| Variabile        | Valore     |
| ---------------- | ---------- |
| `GHCR_USER`      | `tricaman` |
| `DIT_API_TAG`    | `latest`   |
| `DIT_PING_TAG`   | `latest`   |
| `DIT_WORKER_TAG` | `latest`   |

### Database / cache

| Variabile           | Note                                                                            |
| ------------------- | ------------------------------------------------------------------------------- |
| `POSTGRES_USER`     | `dit` (default)                                                                 |
| `POSTGRES_PASSWORD` | **random**, generata con `openssl rand -base64 36 \| tr -d '=+/' \| head -c 40` |
| `POSTGRES_DB`       | `dit` (default)                                                                 |

`DATABASE_URL` e `REDIS_URL` sono **costruite automaticamente nel `docker-compose.prod.yml`** e iniettate nei container — non vanno settate in `.env.prod`.

### Secret applicativi

| Variabile            | Generazione                 | Note                                               |
| -------------------- | --------------------------- | -------------------------------------------------- |
| `JWT_SECRET`         | `openssl rand -hex 32`      | **DEVE coincidere** in `dit-api` e `dit-ping`      |
| `BETTER_AUTH_SECRET` | `openssl rand -hex 32`      |                                                    |
| `TRUSTED_ORIGINS`    | `dit://,https://api.mydit.app,https://dit-api...` | Origini accettate da BetterAuth (mobile + browser). Include l'host legacy |
| `BETTER_AUTH_URL`    | *(vuota)*                   | Vuota = base URL derivata per richiesta dall'host. Valorizzarla fissa un'origine sola: è la leva di rollback del cutover |

### Email (Amazon SES)

| Variabile         | Esempio                                 |
| ----------------- | --------------------------------------- |
| `EMAIL_TRANSPORT` | `ses` (oppure `brevo` per il rollback)  |
| `MAIL_FROM`       | `noreply@mydit.app`                     |
| `SMTP_HOST`       | `email-smtp.eu-central-1.amazonaws.com` |
| `SMTP_PORT`       | `587`                                   |
| `SMTP_USER`       | `AKIA...`                               |
| `SMTP_PASS`       | (dal CSV di SES, mostrata una volta)    |

Il dominio del mittente **deve essere un'identità verificata** in SES, con Easy
DKIM e un MAIL FROM personalizzato (`mail.mydit.app`): senza quest'ultimo SPF
non si allinea e DMARC regge sul solo DKIM.

`SMTP_USER`/`SMTP_PASS` sono le credenziali SMTP generate dalla console SES,
**non** le access key IAM, e la password è derivata per regione: vanno create
con la console su eu-central-1.

> **Ricostruendo l'ambiente da zero**: l'account SES dev'essere fuori dalla
> sandbox prima di puntarci il traffico. In sandbox si scrive solo a indirizzi
> verificati, 200 al giorno — ogni OTP verso un utente reale fallirebbe. Non
> riguarda l'ambiente attuale, che è già in produzione su SES.

**Rollback: `EMAIL_TRANSPORT=brevo` e riavvio di `dit-api`.** Le credenziali dei
due provider convivono nello stesso `.env.prod` e il boot valida **solo quelle
del transport selezionato** (`config.module.ts`, `superRefine`), quindi Brevo
resta una via di ritorno immediata finché l'account non è disdetto. Nessun
redeploy, nessun cambio di codice.

Il transport è letto in due punti — lo schema di `config.module.ts` e
`getTransport()` in `common/email/mailer.ts`, che legge `process.env` diretto.
Le due mappature devono restare identiche, o il boot valida un provider mentre
un altro fa gli invii: `config.module.spec.ts` lo blocca.

### OAuth providers (tutti optional)

| Variabile                 | Note                                                             |
| ------------------------- | ---------------------------------------------------------------- |
| `GOOGLE_CLIENT_ID`        | Configurato. Callback: `https://dit-api.../auth/callback/google` |
| `GOOGLE_CLIENT_SECRET`    |                                                                  |
| `FACEBOOK_APP_ID`         | (vuoto — non implementato lato client)                           |
| `FACEBOOK_APP_SECRET`     |                                                                  |
| `MICROSOFT_CLIENT_ID`     | (vuoto — idem)                                                   |
| `MICROSOFT_CLIENT_SECRET` |                                                                  |
| `MICROSOFT_TENANT_ID`     | `common` (default)                                               |

Se in futuro implementi Facebook/Microsoft, basta valorizzare le var senza modificare il backend.

### Firebase (push notification)

| Variabile                       | Formato                                                                                                                                                                                                                               |
| ------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `FIREBASE_SERVICE_ACCOUNT_JSON` | JSON **minified su una sola riga**. Letto da `dit-api` e `dit-worker` con `JSON.parse(env.FIREBASE_SERVICE_ACCOUNT_JSON)`. I `\n` nella `private_key` vanno mantenuti come escape literal `\n` (2 caratteri), NON come newline reali. |

Per generarlo correttamente da un file scaricato da Firebase Console:

```bash
# Sul Mac
python3 -c "import json; print(json.dumps(json.load(open('firebase-prod.json')), separators=(',',':')))"
```

E poi metti il risultato come valore di `FIREBASE_SERVICE_ACCOUNT_JSON=<minified>` (senza virgolette esterne — Docker Compose 2.x le gestisce).

### Tuning ping/WS (dit-ping)

Tutti i seguenti hanno default sensati nel compose; puoi overridarli in `.env.prod`:

| Variabile                      | Default | Significato                                       |
| ------------------------------ | ------- | ------------------------------------------------- |
| `PING_DEFAULT_TTL_SECONDS`     | `3600`  | TTL ping (1h)                                     |
| `PING_MAX_TTL_SECONDS`         | `86400` | TTL massimo (24h)                                 |
| `HUB_MAX_CONNECTIONS_PER_USER` | `5`     | Max device connessi simultanei                    |
| `AUTH_TIMEOUT_SECONDS`         | `5`     | Timeout autenticazione WS                         |
| `HEARTBEAT_INTERVAL_SECONDS`   | `30`    | Ping/pong interval (sotto soglia CF 100s)         |
| `HEARTBEAT_TIMEOUT_SECONDS`    | `60`    | Timeout heartbeat                                 |
| `BULL_QUEUE_NAME`              | `notif` | Nome coda BullMQ (deve coincidere con dit-worker) |
| `WORKER_CONCURRENCY`           | `10`    | Job paralleli del worker                          |

---

## Troubleshooting / lessons learned

Decisioni e bug risolti durante il setup. Documento qui per evitare di doverli scoprire di nuovo.

### dit-api: `Cannot find module '/app/dist/main.js'`

**Sintomo**: container in restart loop al primo deploy.

**Causa**: il codice in `src/` importa `generated/prisma/client` (output di `prisma generate`). TypeScript con `nest build` calcola il `rootDir` come "common ancestor" di tutti i file inclusi → siccome `generated/` sta fuori da `src/`, il root diventa la project root e l'output va in `dist/src/main.js` invece di `dist/main.js`.

**Fix**: nel Dockerfile di `dit-api`, `CMD ["node", "dist/src/main.js"]` (vedi `@/Users/trica/personal/dit/dit-api/Dockerfile`).

### dit-api: `connect ECONNREFUSED 127.0.0.1:6379` (Redis)

**Sintomo**: dit-api parte ma fallisce a connettersi a Redis.

**Causa**: `BullModule.forRoot({ connection: { host: 'localhost', port: 6379 } })` era hardcoded su localhost. Funzionava in dev (Redis su host) ma in prod il container deve raggiungere `redis:6379` (nome di servizio Docker).

**Fix**: in `src/app.module.ts` (`@/Users/trica/personal/dit/dit-api/src/app.module.ts`):

```ts
import { Redis } from 'ioredis';
// ...
BullModule.forRoot({
  connection: new Redis(
    process.env['REDIS_URL'] ?? 'redis://localhost:6379',
    { maxRetriesPerRequest: null },
  ),
}),
```

### dit-notifications-worker: TypeScript 6.0 deprecation

**Sintomo**: build fallisce con errori TS5107/TS5011/TS5101 (`moduleResolution=node10` deprecated, `rootDir` mancante, `baseUrl` deprecated).

**Fix**: in `tsconfig.json` aggiunto `"rootDir": "./src"` + `"ignoreDeprecations": "6.0"`, rimosso `"baseUrl"`.

### Dockerfile dit-api: `prisma migrate deploy` fallisce

**Sintomo**: `migrate.sh` non trova lo schema in produzione.

**Fix**: nel runner stage del Dockerfile, copia anche `prisma/` e `prisma.config.ts`:

```dockerfile
COPY --from=builder /app/prisma ./prisma
COPY --from=builder /app/prisma.config.ts ./
```

### Caddy "502 Bad Gateway" + log "lookup dit-api on 127.0.0.11:53: server misbehaving"

**Sintomo**: Caddy non riesce a risolvere il nome dei container backend.

**Causa**: il container backend è down (in restart loop). 127.0.0.11 è il DNS interno di Docker, "server misbehaving" significa che il record non è risolvibile perché il container non è up.

**Fix**: cerca il container in restart con `docker compose ps`, e guarda `docker compose logs <service>` per capire perché crasha. Caddy si riconnette automaticamente quando il backend torna su.

### DNS: cache pubblica restituisce vecchio IP

**Sintomo**: dopo aver cambiato IP del droplet, `dig @8.8.8.8 +short XX.mydit.app` restituisce ancora il vecchio IP per molto tempo.

**Causa**: TTL alto (es. 14400 = 4h). Anche se i nameserver autoritativi (Keliweb) sono già aggiornati, le cache pubbliche (Google DNS, ISP) continuano a restituire il vecchio finché il TTL non scade.

**Verifica autoritativa**:

```bash
for ns in $(dig NS mydit.app +short); do
  echo "[$ns]"
  dig @$ns +short ws.mydit.app
done
```

**Mitigazione futura**: tieni TTL=`60` o `300` sui sottodomini che potrebbero cambiare IP. Quando tutto è stabile, alza TTL per ridurre query DNS.

### Reboot droplet: `ssh root@... reboot` non riavvia

**Sintomo**: lanci `reboot` ma il droplet resta su.

**Causa**: l'SSH chiude la sessione prima che il systemd schedule il riavvio.

**Fix**: usa `systemctl --no-block reboot` (non blocca la sessione SSH e schedula il reboot in background):

```bash
ssh root@178.105.228.38 "systemctl --no-block reboot"
sleep 60   # aspetta che torni up
```

### Firebase JSON: quoting nelle env var

**Sintomo**: `dit-worker` fallisce con `FIREBASE_SERVICE_ACCOUNT_JSON: Too small: expected string to have >=1 characters`.

**Causa**: copia-incolla del JSON formattato (multi-riga) nel `.env.prod`. Docker Compose legge solo la prima riga e tronca.

**Fix**: minified su UNA SOLA RIGA. Usa lo script Python documentato in [Variabili `.env.prod` § Firebase](#firebase-push-notification). Verifica con:

```bash
awk '/^FIREBASE_SERVICE_ACCOUNT_JSON=/{print "length="length($0)}' /opt/dit/.env.prod
# Atteso: ~2300-2500 caratteri su una sola riga
```

### `open /opt/dit/.env.prod: permission denied`

**Symptom**: `docker compose ... --env-file .env.prod` fails as `dit`, and so does every CI deploy (`deploy.sh` now stops early with an explicit message). From 2026-09-12 to 2026-10-01 this silently kept dit-api on a stale image.

**Cause**: `.env.prod` was edited as root (`sudo sed -i`, `sudo nano`, or a root shell). `sed -i` recreates the file owned by whoever runs it, so it became `root:root 600`.

**Fix**: edit `.env.prod` as `dit`. If it already happened:

```bash
ssh root@178.105.228.38 'chown dit:dit /opt/dit/.env.prod && chmod 600 /opt/dit/.env.prod'
```

### iOS push: `Invalid APNs credential.`

**Symptom**: Android pushes arrive, iOS ones never do. dit-worker logs `FCM send failed` (single sends) or `FCM multicast tokens failed` (broadcasts) with `Invalid APNs credential.` / `messaging/third-party-auth-error`.

**Cause**: the APNs auth key in the Firebase console (project `dit-prod-3e6a7`, Cloud Messaging, app `com.mariustrica.dit`) is revoked, belongs to another Apple team, or was entered with the wrong Key ID / Team ID. Team is `XFS75S4BYM`.

**Fix**: upload a valid `.p8` with its Key ID and Team ID `XFS75S4BYM`. To check a key without delivering anything, POST to `https://api.push.apple.com/3/device/<64 zeros>` with an ES256 JWT (`kid` = Key ID, `iss` = Team ID) and `apns-topic: com.mariustrica.dit`: `400 BadDeviceToken` means the key is valid, `403 InvalidProviderToken` means it is not.

```bash
ssh dit@178.105.228.38 'docker logs --since 24h dit-dit-worker-1 2>&1 | grep -E "send failed|tokens failed"'
```

### Bot scan dei log Caddy (`/setup.php`, `/_internal/api/setup.php`)

**Sintomo**: log di Caddy pieni di richieste tipo `GET /setup/`, `POST /_internal/api/setup.php?action=exists`.

**Causa**: bot scanner che cercano vulnerabilità WordPress / PHP. Innocuo per noi (non runniamo PHP), ma rumoroso.

**Mitigazione (opzionale)**: in Caddyfile, blocca path noti malicious con un `respond 444` (chiude la connessione senza rispondere) per pattern tipo `/setup.php`, `/wp-admin/*`, `/.env`, ecc. Esempio:

```caddyfile
@bots path_regexp ^/(setup\.php|wp-(admin|login|content)|\.env|phpmyadmin)
respond @bots "" 444
```

Per ora i bot non causano problemi, lo lasciamo come ottimizzazione futura.

---

## File del repo

```
dit-infra/
├── docker-compose.prod.yml      # orchestrazione completa
├── Caddyfile                    # reverse proxy + TLS auto
├── .env.prod.example            # template (NO secret reali)
├── .gitignore                   # esclude .env.prod e backups/
├── README.md                    # questo file
└── scripts/
    ├── bootstrap-droplet.sh     # setup iniziale Ubuntu (one-shot, come root)
    ├── deploy.sh                # pull + migrate + restart (full o per servizio)
    ├── migrate.sh               # prisma migrate deploy via container one-shot
    └── backup-postgres.sh       # pg_dump + gzip + rotazione 14gg
```

Tutto il resto (build immagini, codice applicativo, schema DB) è nei repo applicativi. Questo repo deve poter ricostruire l'intera produzione partendo da un droplet vuoto seguendo la sezione [Setup completo da zero](#setup-completo-da-zero-disaster-recovery).
