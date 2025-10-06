# Mlx.Home.k3s.Flux

MLX-Home services are defined here, along with all Kubernetes GitOps configuration managed by Flux.

## Repository Structure
```
├── apps/
|   ├── app1/
|   |   ├── base/
|   |   |   ├── kustomization.yaml
|   |   |   ├── app1_ResourceDefinition1.yaml
|   |   |   ├── app1_ResourceDefinition2.yaml
|   |   |   └── app1_ResourceDefinition3.yaml
|   |   └── overlays/
|   |       ├── env1/
|   |       |   ├── kustomization.yaml                    # references ../../base/ + patch files
|   |       |   ├── app1_ResourceDefinition1_env1.yaml    # Resource 1 patches for env1
|   |       |   └── app1_ResourceDefinition2_env1.yaml    # Resource 2 patches for env1
|   |       ├── env2/
|   |       |   ├── kustomization.yaml                    # references ../../base/ + patch files
|   |       |   ├── app1_ResourceDefinition2_env2.yaml    # Resource 2 patches for env2
|   |       |   └── app1_ResourceDefinition3_env2.yaml    # Resource 3 patches for env2
|   |       └── env3/
|   |           └── kustomization.yaml
|   ├── app2/
|   ├── app3/
|   |
├── clusters/
|   ├── cluster1/
|   |   ├── flux-system/         # auto-generated from flux-bootstrap
|   |   └── kustomization.yaml   # main kustomization pointing to environment stage(s)
|   ├── cluster2/
|   ├── cluster3/
|   |
├── environments/
|   ├── env1/
|   |   ├── 00_initalize/kustomization.yaml   # initalize stage apps / resources
|   |   ├── 01_recovery/kustomization.yaml    # recovery stage apps / resources
|   |   ├── 02_live/kustomization.yaml        # live stage apps / resources
|   |   └── namespaces/
|   |       ├── kustomization.yaml
|   |       ├── namespace1_Namespace.yaml
|   |       ├── namespace2_Namespace.yaml
|   |       ├── namespace3_Namespace.yaml
|   |       |
|   ├── env2/
|   ├── env3/
|   |
└── kubeseal/        # Clean folder that via .gitignore ignores EVERYTHING except what's already there
                     # Useful for staging secrets while doing sealed secret shenanagains.
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

Below are instructions for the stages used to bootstrap this Flux CD repository. 
These instructions assume that the cluster is all "NET NEW", with nothing already pre-installed.
If you are attempting to do this on a cluster that is already bootstrapped, your milage may vary

### 1. Bootstrap Flux

1. Install Flux CLI: https://fluxcd.io/flux/installation/
1. Prepare SSH Key for Flux
   1. Generate the key
      ```bash
      ssh-keygen -t ed25519 -C "29760146+TheNightAngel17@users.noreply.github.com" -f /home/lemonsml/.ssh/gh_flux_key -P ""
      ```
   1. Upload the public key to the Git host (GitHub) for repo access.
1. Ensure that for the cluster, the enviornments that you want have only the `00_initalize` folder in the cluster's kustomization, and is committed to the `main` branch
   ```yaml
   #### '$/clusters/{{cluster}}/kustomization.yaml'
   ---
   apiVersion: kustomize.config.k8s.io/v1beta1
   kind: Kustomization
   resources:
   - ../../environments/{{env}}/00_initalize
   # - ../../environments/{{env}}/01_recovery
   # - ../../environments/{{env}}/02_live
   ```
1. Bootstrap the Flux repository
   ```bash
   flux bootstrap git \
       --url=ssh://git@github.com/TheNightAngel17/Mlx.Home.k3s.Flux \
       --branch=main \
       --path=clusters/{{cluster}} \
       --private-key-file=/path/to/ssh//gh_flux_key
   ```

### 2. Configure Sealed-Secrets

1. Locate the ENV certificate values that are needed for the environemnts going into the cluster
1. Apply the `.yaml` file associated to the credentials to the cluster
   ```bash
   kubectl apply -f `H:\path\to\some\manifest.yaml`
   ```
1. Restart the sealed-secrets services
   ```bash
   kubectl rollout restart deployment.apps/sealed-secrets -n kube-system
   ```
1. Ensure that the key from the manifest was picked up
   - run the log command
      ```bash
      kubectl logs deployment.apps/sealed-secrets -n kube-system
      ```
   - You should see a log saying `... "registered private key" <name-of-key>`

### 3. Data Recovery & Platform PRep

1. Add the `01_recovery` folder to the cluster's main kustomization file and commit it to the `main` branch in the git host (GitHub).
   ```yaml
   #### '$/clusters/{{cluster}}/kustomization.yaml'
   ---
   apiVersion: kustomize.config.k8s.io/v1beta1
   kind: Kustomization
   resources:
   - ../../environments/{{env}}/00_initalize
   - ../../environments/{{env}}/01_recovery
   # - ../../environments/{{env}}/02_live
   ```
1. Wait for the changes to come in via Flux CD & for longhorn to initialize
   - Monitoring Flux Logs
      ```bash
      flux logs -f
      ```
   - Monitoring longhorn namespace
      ```bash
      kubectl get all -n longhorn-system
      ```
   - Wait for ALL services to show up 
      > Note: Longhorn service list should be QUITE LONG

#### Longhorn Dashboard & Data Recovery

1. forward the port locally
   ```bash
   kubectl port-forward service/longhorn-frontend 8675:80 -n longhorn-system
   ```
1. Open the dashboard - http://localhost:8675/#/dashboard
1. Perform Data recovery
   1. Backup tab: create Disaster Recovery Volumes
   1. Wait for volumes to become Healthy (with warning)
   1. Activate Disaster Recovery Volumes (block device)
   1. Create PV/PVC (Use Previous PVC = checked)

#### Traefik Dashboard

1. forward the port locally
   > NOTE: this command forwards the pod's port, not the svc, as the traefik svc is not exposing the dashboard's entry point ports. This is by design for security reasons.
   ```bash
   kubectl -n traefik port-forward pod/$(kubectl -n traefik get pods -l app.kubernetes.io/name=traefik -o jsonpath='{.items[0].metadata.name}') 8676:8080
   ```
1. attempt to enter the dashboard - http://localhost:8676/dashboard/#/


### 4. Deploy Live Apps

1. Add the `02_live` folder to the cluster's main kustomization file and commit it to the `main` branch in the git host (GitHub).
   ```yaml
   #### '$/clusters/{{cluster}}/kustomization.yaml'
   ---
   apiVersion: kustomize.config.k8s.io/v1beta1
   kind: Kustomization
   resources:
   - ../../environments/{{env}}/00_initalize
   - ../../environments/{{env}}/01_recovery
   - ../../environments/{{env}}/02_live
   ```
1. Validate all apps are up and running
   - Monitor namespace
      ```bash
      kubectl get all -n {{namespace}}
      ```
   - Monitor Persistant Data
      - Open Longhorn Dashboard (instructions above)
      - Watch as PVCs get attached to pods
   - Monitor Ingress Routs
      - Open Traefik Dashboard
      - Enter the HTTP section, and view the HTTP Routers, Services, & Middlewares



## Adding / Updating an applicaiton

1. Copy PROD (base) manifest(s) into `apps/<app>/base` (must reflect canonical prod state).
2. Create/adjust dev patches only where drift is required.
3. Ensure dev `kustomization.yaml` uses `patchesStrategicMerge` and lists only necessary patches.
4. Add overlay path to `clusters/<env>/full/kustomization.yaml` (both dev & prod for new apps—prod just references base).
5. For any IngressRoute, always add a matching dev patch.

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
