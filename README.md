# Mlx.Home.k3s.Flux

MLX-Home services are defined here, along with all Kubernetes GitOps configuration managed by Flux.

## Repository Structure
```
apps/
  <app>/
    base/                 # Canonical PROD state (exact copy of former mlx-home-prd definitions)
    overlays/
      dev/                # Dev-specific patches (only where drift exists)
      prd/                # Points back to base only (no patches unless intentional future prod drift)
clusters/
  dev/
    namespaces.yaml       # All namespaces (includes dev-only apps like home-assistant)
    init/kustomization.yaml
    full/kustomization.yaml
    flux-system/          # Created/managed by flux bootstrap
  prd/
    namespaces.yaml       # All prod namespaces
    init/kustomization.yaml
    full/kustomization.yaml
    flux-system/
```

### Patching Rules
- Base = PROD truth. Never edit base directly for environment drift.
- Dev overlays use `patchesStrategicMerge` only for actual differences.
- No PROD patches unless a deliberate prod-only change is required later.
- IngressRoute: every IngressRoute gets a dev patch (host change at minimum) with:
  - Full `spec.routes` reproduced
  - `spec.entryPoints` removed in patch
  - `spec.tls` included if tls present (or intentionally added) in dev
- SealedSecret: dev patch ONLY contains differing `spec.encryptedData` keys.
- HelmRelease: dev patch only when values differ (image tag, sourceRef, domains, backupTarget, resources, etc.). Remove unchanged keys from patches.
- Naming: `<app>_<resource-kind>_dev.yaml` (underscores between tokens; internal hyphens preserved).
- Never create prod patches during normal sync operations.

### Namespaces
All namespaces are now centralized per environment in `clusters/<env>/namespaces.yaml` and applied by both `init` and `full` kustomizations.

## Installation Instructions

### 1. Install Sealed-Secrets

To install controller:
```bash
kubectl apply -f https://github.com/bitnami-labs/sealed-secrets/releases/download/v0.x.x/controller.yaml
```
Apply the sealed-secrets root TLS key (private location, not in repo):
```bash
kubectl apply -f <sealed-secrets-key.yaml>
```
Then delete the auto-generated secret and restart the controller pod so it picks up the provided key.

### 2. Prepare Flux
We use Flux CD for reconciliation.

#### Install Flux CLI
Follow: https://fluxcd.io/flux/installation/

#### SSH Key (if needed)
```bash
ssh-keygen -t ed25519 -C "29760146+TheNightAngel17@users.noreply.github.com" -f /home/lemonsml/.ssh/gh_flux_key -P ""
```
Add the public key to the Git host (GitHub) for repo access.

### 3. Data Recovery (Longhorn)
Longhorn provides the storage layer; use it to restore volumes before deploying full workloads.

#### Bootstrap Init Branch (Longhorn + Namespaces Only)
The `init` branch is still used for a minimal bring-up (namespaces + Longhorn) so volumes can be restored safely before app workloads start.

Dev:
```bash
flux bootstrap git \
  --url=ssh://git@github.com/TheNightAngel17/Mlx.Home.k3s.Flux \
  --branch=main \
  --path=clusters/dev \
  --private-key-file=/home/lemonsml/.ssh/gh_flux_key
```

```powershell
flux bootstrap git `
  --url=ssh://git@github.com/TheNightAngel17/Mlx.Home.k3s.Flux `
  --branch=main `
  --path=clusters/dev `
  --private-key-file=/home/lemonsml/.ssh/gh_flux_key
```


Prod:
```bash
flux bootstrap git \
  --url=ssh://git@github.com/TheNightAngel17/Mlx.Home.k3s.Flux \
  --branch=main \
  --path=clusters/prd/init \
  --private-key-file=/home/lemonsml/.ssh/gh_flux_key
```

#### Access Longhorn UI
```bash
kubectl port-forward service/longhorn-frontend 8675:80 -n longhorn-system
```
Open http://localhost:8675/#/dashboard and perform volume restoration:
1. Backup tab: create Disaster Recovery Volumes
2. Wait for volumes to become Healthy (with warning)
3. Activate Disaster Recovery Volumes (block device)
4. Create PV/PVC (Use Previous PVC = checked)

### 4. Bootstrap Full Repository
After volumes restored, bootstrap (or switch to) the `main` branch which reconciles all applications via `clusters/<env>/full`.

Dev:
```bash
flux bootstrap git \
  --url=ssh://git@github.com/TheNightAngel17/Mlx.Home.k3s.Flux \
  --branch=main \
  --path=clusters/dev/full \
  --private-key-file=/home/lemonsml/.ssh/gh_flux_key
```
Prod:
```bash
flux bootstrap git \
  --url=ssh://git@github.com/TheNightAngel17/Mlx.Home.k3s.Flux \
  --branch=main \
  --path=clusters/prd/full \
  --private-key-file=/home/lemonsml/.ssh/gh_flux_key
```

Check readiness:
```bash
kubectl get pods --all-namespaces -o wide
```

## Adding / Updating an applicaiton

1. Copy PROD (base) manifest(s) into `apps/<app>/base` (must reflect canonical prod state).
2. Create/adjust dev patches only where drift is required.
3. Ensure dev `kustomization.yaml` uses `patchesStrategicMerge` and lists only necessary patches.
4. Add overlay path to `clusters/<env>/full/kustomization.yaml` (both dev & prod for new apps—prod just references base).
5. For any IngressRoute, always add matching dev patch.

### Adding Sealed Secrets
- Generate plaintext Secret locally, ideally in `kubeseal/` somewhere so .gitignore ensures GIT doens't pick it up
- Seal with the cluster-specific public key for your environment(s)
```powershell
Get-Content .\app-name_Secret.yaml | kubeseal --format=yaml --cert C:\Path\To\env_cert.crt > app-name_SealedSecret.yaml
```
- If this is a PRD environment secret, add it to `apps/<app>/base`
- If this is an overlay secret, replace only the `spec.encryptedData` map in the corresponding patch file
- Never add unrelated keys to the patch


## 7. Conventions Summary
- File name tokens separated by `_`, internal hyphens preserved.
- Dev-only apps (e.g., home-assistant) still list their namespace only in dev `namespaces.yaml`.
- Avoid accidental PROD drift by reviewing patches: prod overlays should normally contain only a `kustomization.yaml` pointing to `../../base`.

## 8. Future Changes
If intentional prod drift is required, introduce a prod patch (exception case) and document rationale in the PR.

---
Questions or improvements: open an issue.
