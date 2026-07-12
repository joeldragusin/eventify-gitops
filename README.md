# Eventify GitOps

GitOps-managed deployment of the **Eventify** backend (Node.js/Express + PostgreSQL/Prisma + JWT) on Kubernetes, driven by **FluxCD**. Runs locally on **k3d** and is designed to promote to **EKS** by re-bootstrapping Flux against a different path.

The cluster is disposable; this repository is the source of truth. Everything below rebuilds the entire stack from scratch on a fresh machine.

---

## Architecture

```
  Git repo (this)  ──pull──▶  Flux (in cluster)  ──reconciles──▶  Kubernetes
        │                                                              │
        ├─ clusters/local/        Flux entrypoint for the local cluster
        │    ├─ flux-system/      Flux's own manifests (bootstrap-generated)
        │    ├─ infrastructure.yaml   Kustomization → ./infrastructure
        │    └─ apps.yaml              Kustomization → ./apps (depends on infrastructure)
        │
        ├─ infrastructure/        platform layer (Helm via Flux)
        │    ├─ traefik/          ingress controller (L7)
        │    └─ metrics-server/   CPU/memory metrics (feeds the HPA)
        │
        └─ apps/eventify/         the application
             ├─ backend Deployment (+ HPA, resources, probes)
             ├─ Postgres StatefulSet (+ PVC)
             ├─ Prisma migrate Job
             └─ SOPS-encrypted Secret (DB creds + JWT)
```

Request path (local): `localhost:8080` → k3d load balancer → Traefik → Service → backend pod → Postgres.

---

## Prerequisites

Install on the host (WSL Ubuntu / Linux):

- **Docker** (running)
- **k3d** — local Kubernetes
- **kubectl**
- **flux** CLI
- **helm** (used for inspection; Flux does the actual installs)
- **sops** + **age** — secret encryption/decryption
- A **GitHub account** with:
  - a fork/copy of this repo (Flux commits to it)
  - a **Personal Access Token** with `repo` scope (for Flux)

Environment variables (e.g. in `~/.bashrc`):

```bash
export GITHUB_USER="<your-github-username>"
export GITHUB_TOKEN="<your-PAT-with-repo-scope>"
```

---

## Setup on a fresh environment

### 1. Create the local cluster

Traefik and metrics-server are disabled as k3s bundled addons — this repo deploys its own via Flux.

```bash
k3d cluster create eventify \
  --servers 1 \
  --agents 2 \
  --port "8080:80@loadbalancer" \
  --k3s-arg "--disable=traefik@server:*" \
  --k3s-arg "--disable=metrics-server@server:*"

kubectl get nodes        # 3 nodes, all Ready
```

### 2. Provide the SOPS age key (required for secret decryption)

The private age key is **never** stored in Git. You need the same `keys.txt` that encrypted the secret.

- If you already have it: it lives at `~/.config/sops/age/keys.txt`.
- If starting fresh (new key), generate one and **re-encrypt** `apps/eventify/secret.yaml` with its public key (see "Secrets" below):

```bash
mkdir -p ~/.config/sops/age
age-keygen -o ~/.config/sops/age/keys.txt      # only if you don't already have a key
```

### 3. Bootstrap Flux

```bash
flux check --pre

GITHUB_TOKEN=$GITHUB_TOKEN flux bootstrap github \
  --owner=$GITHUB_USER \
  --repository=eventify-gitops \
  --branch=main \
  --path=clusters/local \
  --personal \
  --token-auth
```

This installs Flux, commits its own manifests under `clusters/local/flux-system/`, and starts watching the repo.

### 4. Give Flux the private key (so it can decrypt secrets)

This is the one manual, non-GitOps step — the decryption key cannot live in Git.

```bash
kubectl create secret generic sops-age \
  --namespace=flux-system \
  --from-file=age.agekey=$HOME/.config/sops/age/keys.txt
```

### 5. Reconcile and let Flux build everything

```bash
flux reconcile kustomization flux-system --with-source
```

Flux now deploys Traefik, metrics-server, Postgres, the backend, the migration Job, and the HPA.

---

## Verify

```bash
flux get kustomizations                 # flux-system, infrastructure, apps → all Ready
flux get helmreleases -A                # traefik, metrics-server → Ready
kubectl get pods -n eventify            # backend + postgres-0 Running, migrate Completed
kubectl get hpa -n eventify             # TARGETS shows a % (not <unknown>)
kubectl top pods -n eventify            # metrics-server working

# app reachable end-to-end:
kubectl port-forward -n eventify deploy/eventify-backend 5000:5000
curl -i http://localhost:5000/health    # 200 OK
```

---

## Secrets (SOPS + age)

Application secrets live encrypted in `apps/eventify/secret.yaml`. Only the **values** are encrypted (`ENC[...]`); structure stays readable so Flux recognizes the Secret. Flux decrypts at apply time using the `sops-age` key from step 4.

Config lives in `.sops.yaml` at the repo root (holds the **public** key + rules).

To edit a secret:
```bash
sops apps/eventify/secret.yaml          # opens decrypted, re-encrypts on save
```

To rotate / re-encrypt with a new key, update the `age:` public key in `.sops.yaml`, then:
```bash
sops --encrypt --in-place apps/eventify/secret.yaml
```

**Never commit plaintext secrets.** Verify before committing:
```bash
git show :apps/eventify/secret.yaml | grep ENC   # must show ciphertext
```

> Note: Postgres reads its credentials from the same Secret via `secretKeyRef`, so credentials live in exactly one place. Changing the DB password requires re-initializing Postgres (delete the StatefulSet + PVC), since Postgres only applies credentials on first boot.

---

## Autoscaling demo (HPA)

The backend has an HPA (min 1, max 5, target 50% CPU), fed by metrics-server.

```bash
# watch:
watch -n 2 'kubectl get hpa -n eventify; echo ---; kubectl get pods -n eventify'

# load (hits the Service, so traffic spreads across replicas → drives scale-up):
chmod +x scripts/load-test.sh
./scripts/load-test.sh 50

# stop + clean up:
kubectl delete pod load-gen -n eventify
```

Replicas climb toward 5 under load, then scale back to 1 after a cooldown (~5 min).

---

## Cluster lifecycle

```bash
k3d cluster stop eventify      # pause (data on PVC survives)
k3d cluster start eventify     # resume
k3d cluster delete eventify    # destroy (rebuild via steps 1–5)
```

After a `delete` + recreate, repeat setup steps 1, 3, 4, 5 (step 2's key persists in `~/.config`).

---

## Technical choices & trade-offs

- **Traefik over ingress-nginx** — the community ingress-nginx controller was retired (archived, unpatched) in 2026; running an unmaintained controller in the TLS path is a security risk. Traefik is actively maintained, is the k3s default, and supports both classic Ingress and the Gateway API.
- **Postgres in-cluster (StatefulSet)** — self-contained for local/demo. Production on AWS would use **RDS** (managed backups, Multi-AZ); the backend only reads `DATABASE_URL`, so it's a config swap.
- **SOPS + age for secrets** — keeps everything in Git (GitOps intact) while encrypting sensitive values; the decryption key lives only in the cluster. On EKS, SOPS can be backed by AWS **KMS** instead of a local age key.
- **Separate app-code and GitOps repos** — application code and deployment config have different lifecycles; the image is built from the app repo and referenced here by immutable tag.
- **metrics-server needs `--kubelet-insecure-tls` on k3d** — k3d's kubelet uses self-signed certs; this flag is local-only and removed on EKS.

---

## Repository layout

```
eventify-gitops/
├── .sops.yaml                       # SOPS rules + public key
├── clusters/local/                  # Flux entrypoint for the local cluster
│   ├── flux-system/                 # bootstrap-generated
│   ├── infrastructure.yaml
│   └── apps.yaml
├── infrastructure/
│   ├── kustomization.yaml
│   ├── traefik/
│   └── metrics-server/
├── apps/
│   ├── kustomization.yaml
│   └── eventify/
│       ├── namespace.yaml
│       ├── deployment.yaml          # backend + resources
│       ├── postgres.yaml            # StatefulSet + Service + PVC
│       ├── secret.yaml              # SOPS-encrypted
│       ├── migrate-job.yaml         # prisma migrate deploy
│       └── hpa.yaml
└── scripts/
    └── load-test.sh
```
