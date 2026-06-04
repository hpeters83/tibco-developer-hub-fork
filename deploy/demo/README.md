# Public demo deployment — TIBCO Developer Hub

Runbook for hosting a **public, unauthenticated** demo of the Developer Hub on a single
small AWS Lightsail instance, with automatic HTTPS via Caddy.

## How it works

```
Route53 A record (demo.<domain>)  ──►  Lightsail static IP
                                          │
                                          ▼
                                    Caddy  :80/:443  (auto Let's Encrypt TLS)
                                          │  reverse_proxy (compose network)
                                          ▼
                                    devhub container  :7007
                                      node packages/backend --config app-config.demo-environment.yaml
                                      (serves the frontend + backend APIs on one origin)

GitHub Actions (.github/workflows/demo-image.yml): build Dockerfile.demo ──► push to GHCR
Lightsail host (./redeploy.sh): docker compose pull && up -d
```

The whole "is it safe?" story lives in [`app-config.demo-environment.yaml`](../../app-config.demo-environment.yaml):
guest-only auth, in-memory SQLite, **no GitHub token, no OIDC/Control-Plane secrets**, catalog
sourced from the public repo. There is nothing sensitive for a visitor to extract. Functionality
that needs credentials (create-template publish, marketplace "install" → scaffolder publish) fails
by design; browsing the catalog, integration topology, and marketplace works fully.

## One-time setup

### 1. Publish the image (GitHub Actions)

The `Build demo image` workflow builds `Dockerfile.demo` and pushes to
`ghcr.io/<owner>/<repo>-demo`. Trigger it by pushing to `main` or via **Actions → Build demo image
→ Run workflow**.

After the first push, make the GHCR package **public** so the host can pull without credentials:
**GitHub → your profile/org → Packages → `<repo>-demo` → Package settings → Change visibility →
Public**. (If you prefer to keep it private, you'll `docker login ghcr.io` on the host in step 4.)

### 2. Provision the Lightsail instance

Console: **Lightsail → Create instance → Linux/Unix → OS only → Ubuntu 22.04 LTS → 2 GB / 2 vCPU
plan (~$12/mo)**. Then:

- **Networking → attach a static IP** to the instance (note the IP).
- **Networking → IPv4 Firewall**: allow **HTTP (80)** and **HTTPS (443)** from anywhere; restrict
  **SSH (22)** to your own IP. **Do not** open 7007 — only Caddy is public.

CLI equivalent (optional):

```bash
aws lightsail create-instances \
  --instance-names devhub-demo \
  --availability-zone <az> \
  --blueprint-id ubuntu_22_04 \
  --bundle-id medium_3_0          # 2 GB / 2 vCPU
aws lightsail allocate-static-ip --static-ip-name devhub-demo-ip
aws lightsail attach-static-ip --static-ip-name devhub-demo-ip --instance-name devhub-demo
aws lightsail open-instance-public-ports --instance-name devhub-demo \
  --port-info fromPort=80,toPort=80,protocol=TCP
aws lightsail open-instance-public-ports --instance-name devhub-demo \
  --port-info fromPort=443,toPort=443,protocol=TCP
```

### 3. Point DNS at the instance (Route53)

Add an **A record** for `demo.<domain>` → the Lightsail static IP in your hosted zone (console, or
`aws route53 change-resource-record-sets`). Wait for it to resolve (`dig +short demo.<domain>`)
before starting Caddy, or cert issuance will fail.

### 4. Install Docker + deploy

SSH in, then:

```bash
sudo apt-get update && sudo apt-get install -y docker.io docker-compose-v2 git
sudo usermod -aG docker "$USER" && newgrp docker   # log out/in if needed

# Get just this deploy folder (or git clone the repo and cd into deploy/demo)
git clone https://github.com/<owner>/<repo>.git
cd <repo>/deploy/demo

cp .env.example .env
# Edit .env: DEVHUB_IMAGE, DEMO_DOMAIN, and APP_BASE_URL (the bare https://<domain>, no path)

# Only if the GHCR package is PRIVATE:
# echo <a-PAT-with-read:packages> | docker login ghcr.io -u <user> --password-stdin

./redeploy.sh
```

Caddy will obtain a TLS cert on first start (needs DNS resolving + 80/443 open). Watch logs with
`docker compose logs -f caddy`.

## Verify

```bash
curl -I https://demo.<domain>/                                   # → 200, valid TLS
curl -sS -o /dev/null -w '%{http_code} %{content_type}\n' \
  https://demo.<domain>/static/                                  # assets serve at root
```

In a browser, open `https://demo.<domain>/` and confirm:
- it loads **as guest with no sign-in prompt** (no TIBCO Control Plane login),
- the catalog, **integration topology**, and **marketplace** populate,
- a create-template "publish"/marketplace "install" fails gracefully (no token — expected).

Negative checks: `https://demo.<domain>:7007` must be unreachable from outside; no endpoint should
return any secret.

## Updates

1. Push changes to `main` (or run the workflow manually) → a new `:latest` image is published.
2. On the host: `./redeploy.sh`.

The in-memory DB means every redeploy/restart resets the demo to a clean state and re-seeds the
catalog from the public repo.

## Security checklist (run before going public)

- [ ] Container runs `--config app-config.demo-environment.yaml` (it's the image default).
- [ ] No token/secret/clientSecret/password in the config or image (`grep -ri` to confirm).
- [ ] Guest is the only enabled auth provider; no `tibco-control-plane` block present.
- [ ] Firewall: 80/443 public, 22 locked to your IP, 7007 not exposed.
- [ ] Scaffolder endpoints are reachable under guest (publish fails without a token, but
      `tibco:git:clone` etc. still execute). Acceptable for a demo; add Caddy rate-limiting if abused.
