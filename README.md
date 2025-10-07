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


## Branch Workflow

| Environment | Flux `GitRepository` ref | Usage notes |
| --- | --- | --- |
| DEV (`mlx-home-dev`) | `spec.ref.branch = main` by default, temporarily patched to `feature/<name>` while iterating | Use DEV for active development only: point Flux at your feature branch while testing, keep overlays limited to environment drift, and switch it back to `main` immediately once the PR lands. |
| PROD (`mlx-home-prd`) | `spec.ref.branch = main` (never points at feature branches) | PROD always tracks `main`. Post-merge, either wait for Flux to sync or run `flux reconcile` commands. For rollback, revert the `main` branch and push; Flux will redeploy the reverted state. |


## Monitoring & Troubleshooting

- Confirm Flux sees the latest commit and is healthy.
   ```powershell
   flux reconcile source git flux-system -n flux-system
   flux get kustomizations -n flux-system
   flux logs -f
   ```
- Inspect deployment status within the affected namespace.
   ```powershell
   kubectl get pods -n <namespace>
   kubectl describe pod <pod-name> -n <namespace>
   kubectl get events -n <namespace> --sort-by=.lastTimestamp
   ```
- Validate ingress and storage layers:
   - Traefik dashboard: port-forward and inspect HTTP routers/services.
   - Longhorn dashboard: confirm PVCs attach and volumes stay Healthy.
- Capture screenshots or key log excerpts and attach them to the pull request when fixes are user-facing or involve prod-impacting changes.


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
   #### '$/clusters/<cluster>/kustomization.yaml'
   ---
   apiVersion: kustomize.config.k8s.io/v1beta1
   kind: Kustomization
   resources:
   - ../../environments/<env>/00_initalize
   # - ../../environments/<env>/01_recovery
   # - ../../environments/<env>/02_live
   ```
1. Bootstrap the Flux repository
   >NOTE: this should be done on a linux machine until i can figure a way to make it work on powershell
   ```bash
   flux bootstrap git \
       --url=ssh://git@github.com/TheNightAngel17/Mlx.Home.k3s.Flux \
       --branch=main \
       --path=clusters/<cluster> \
       --private-key-file=/path/to/ssh//gh_flux_key
   ```

### 2. Configure Sealed-Secrets

1. Locate the ENV certificate values that are needed for the environemnts going into the cluster
1. Apply the `.yaml` file associated to the credentials to the cluster
   ```powershell
   kubectl apply -f `H:\path\to\some\manifest.yaml`
   ```
1. Restart the sealed-secrets services
   ```powershell
   kubectl rollout restart deployment.apps/sealed-secrets -n kube-system
   ```
1. Ensure that the key from the manifest was picked up
   - run the log command
      ```powershell
      kubectl logs deployment.apps/sealed-secrets -n kube-system
      ```
   - You should see a log saying `... "registered private key" <name-of-key>`

### 3. Data Recovery & Platform PRep

1. Add the `01_recovery` folder to the cluster's main kustomization file and commit it to the `main` branch in the git host (GitHub).
   ```yaml
   #### '$/clusters/<cluster>/kustomization.yaml'
   ---
   apiVersion: kustomize.config.k8s.io/v1beta1
   kind: Kustomization
   resources:
   - ../../environments/<env>/00_initalize
   - ../../environments/<env>/01_recovery
   # - ../../environments/<env>/02_live
   ```
1. Wait for the changes to come in via Flux CD & for longhorn to initialize
   - Monitoring Flux Logs
      ```powershell
      flux logs -f
      ```
   - Monitoring longhorn namespace
      ```powershell
      kubectl get all -n longhorn-system
      ```
   - Wait for ALL services to show up 
      > Note: Longhorn service list should be QUITE LONG

#### Longhorn Dashboard & Data Recovery

1. forward the port locally
   ```powershell
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
   ```powershell
   kubectl -n traefik port-forward pod/$(kubectl -n traefik get pods -l app.kubernetes.io/name=traefik -o jsonpath='{.items[0].metadata.name}') 8676:8080
   ```
1. attempt to enter the dashboard - http://localhost:8676/dashboard/#/


### 4. Deploy Live Apps

1. Add the `02_live` folder to the cluster's main kustomization file and commit it to the `main` branch in the git host (GitHub).
   ```yaml
   #### '$/clusters/<cluster>/kustomization.yaml'
   ---
   apiVersion: kustomize.config.k8s.io/v1beta1
   kind: Kustomization
   resources:
   - ../../environments/<env>/00_initalize
   - ../../environments/<env>/01_recovery
   - ../../environments/<env>/02_live
   ```
1. Validate all apps are up and running
   - Monitor namespace
      ```powershell
      kubectl get all -n <namespace>
      ```
   - Monitor Persistant Data
      - Open Longhorn Dashboard (instructions above)
      - Watch as PVCs get attached to pods
   - Monitor Ingress Routs
      - Open Traefik Dashboard
      - Enter the HTTP section, and view the HTTP Routers, Services, & Middlewares


## Contributing

The ideal way to contribute is to:

1. Create a branch. e.g. `feature/short-description`, `bug/short-description`, `PoC/short-description`
1. Point the DEV cluster to the branch
   1. Ensure you are on the dev cluster
      ```powershell
      kubectl config use-context mlx-home-dev
      ```
   1. Patch the flux git repository to point to your branch
      ```powershell
      kubectl patch gitrepository flux-system -n flux-system --type merge `
          -p '{"spec":{"ref":{"branch":"feature/testme"}}}'
      ```
   1. Force reconciliation
      ```powershell
      flux reconcile source git flux-system -n flux-system
      flux reconcile kustomization flux-system -n flux-system
      ```
1. Make your changes in feature branch and test in DEV
1. Once DEV is functional how you want it to be, make the same changes to prd/base for the apps
   1. Move over any/all patches that are needed
   1. Re-generate and Re-seal any secrets with the prd keys
1. Open a PR from the feature branch to `main`, get reviews, and merge.
1. After merge, wait for PROD Flux to sync `main` (or run a manual reconcile).
   - Complete the pull-request checklist in [`./.github/pull_request_template.md`](.github/pull_request_template.md) when opening the PR. Key highlights:
     - Record the DEV verification steps and any manual dashboards you checked.
     - Confirm prod-ready manifests live in `apps/*/base` with overlays only capturing drift.
     - Note any follow-up actions (secret rotation, migrations) and document an explicit rollback plan.
1. After merge, reset the DEV cluster to the `main` branch
   1. Ensure you are on the dev cluster
      ```powershell
      kubectl config use-context mlx-home-dev
      ```
   1. Patch the flux git repository to point to your branch
      ```powershell
      kubectl patch gitrepository flux-system -n flux-system --type merge `
          -p '{"spec":{"ref":{"branch":"main"}}}'
      ```
   1. Force reconciliation
      ```powershell
      flux reconcile source git flux-system -n flux-system
      flux reconcile kustomization flux-system -n flux-system
      ```
1. For rollback, revert on `main` and let Flux resync that commit
   ```powershell
   git revert <commit-sha>
   ```


### Adding / Updating an applicaiton

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

### Script Utilities

Curent script utilities are in the process of being merged into a local-only powerhell utility. Feel free to use them, but don't get too reliant on them!

- `rename.ps1` - renames files in apps to follow naming conventions
   - known issue: in environment overlays, it doens't currently add the env tag to the file name.
- `kubeseal/Rotate-SealedSecrets.*`
   - performs full key rotation via `kubeseal`
   - able to use outside keys

---
Questions or improvements: open an issue.


Superficial Change