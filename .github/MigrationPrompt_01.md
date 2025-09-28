You are helping me refactor my GitOps repo for Flux.

# Current State
- I have 2 seperate folders for different environemtns of my cluster: `clusters/dev` and `clusters/prod`
- Each folder has subfolder(s) that pertain to specific applicaiton. E.g.
   - `/clusters/mlx-home-dev/bitwarden` contains bitwarden app details for dev
   - `/clusters/mlx-home-prd/bitwarden` contains bitwarden app details for prd
   - `/cluster/mlx-home-dev/mlx-charts` contains, for dev:
      - sub-folders for the different applicaitons 
      - even further sub-folders for seperate instances fo the application for `foundry-vtt`

# Goal State

## File Names Defintions
- All file names can be thought of a concatination of tokens:
   - All tokens should have `-` wherever needed
   - in the name, each token should be split by `_`
- cluster mapping:
   - `mlx-home-dev` => `dev`
   - `mlx-home-prd` => `prd` (not `prod`)
- Files that apply to a an application should be in the format of `{{app-name}}_{{resource-kind}}.yaml`
   - common shorthand vlaues like pvc, pv, crds can be used for resource-kind
   - e.g. `longhorn_helm-repository.yaml` would contain the HelmRepository kind for the longhorn app
   - e.g. `home-assistant_pvc.yaml` would contain the PersistantVolumeClaim for the home-assistant app
- Files that apply to specific overlays should be in the format of `{{app-name}}_{{resource-kind}}_{{env}}.yaml`
   - same restrictions apply to these files as the generic applicaiton files

## App Definitions
- A new `/apps/` folder should be created where appls can be defined
- Each applicaiton type should have a subfolder under `/apps/`, like `/apps/bitwarden/` and `/apps/foundry-vtt-mll/`
- each application should include a `base/` folder for common definitions that are the same for all environments
   - `base/` should be the current "mlx-home-prd" cluster version
- each applicaiton should include a `overlays/{env}/` folder for each environment, defining patches or environment specific resources

## Example Tree
Havave a folder strucutre that looks like:

├── README.md
├── .gitignore
├── .github/ #directory w/ github data
├── apps/
|   ├── application1/
|   |   ├── base/
|   |   |   ├── kustomization.yaml
|   |   |   ├── applicaiton1_resource-definition1.yaml
|   |   |   ├── applicaiton1_resource-definition2.yaml
|   |   |   └── applicaiton1_resource-definition3.yaml
|   |   └── overlays/
|   |       ├── dev/
|   |       |   ├── kustomization.yaml
|   |       |   ├── applicaiton1_some-patch_dev.yaml
|   |       |   └── applicaiton1_sealedsecret_dev.yaml
|   |       └── prd/
|   |           └── kustomization.yaml
|   └── application2/
|       ├── base/
|       |   ├── kustomization.yaml
|       |   ├── applicaiton2_resource-definition1.yaml
|       |   ├── applicaiton2_resource-definition2.yaml
|       |   └── applicaiton2_resource-definition3.yaml
|       └── overlays/
|           ├── dev/
|           |   ├── kustomization.yaml
|           |   ├── applicaiton2_some-patch_dev.yaml
|           |   └── applicaiton2_sealedsecret_dev.yaml
|           └── prd/
|               └── kustomization.yaml
└── clusters/
    ├── dev/
    |   ├── flux-system/ #flux bootstrap puts manifests here
    |   ├── namespaces.yaml
    |   ├── init/
    |   |   └── kustomization.yaml
    |   └── full
    |       └── kustomization.yaml
    └── prd/
        ├── flux-system/ #flux bootstrap puts manifests here
        ├── namespaces.yaml
        ├── init/
        |   └── kustomization.yaml
        └── full
            └── kustomization.yaml

## App Definitions:
- bitwarden
- cert-manager
- cloudflared
- home-assistant (currently dev only)
- jellyfin
- longhorn
- foundry-vtt
   - mll
   - kf
   - tjk
   - tw
- ddb-proxy
- mlx-portfolio
- nvidia
- pihole
- traefik

## Environment Overlay Rules (Critical)
1. base = canonical PROD state. It already equals mlx-home-prd. Do NOT create patches for prod that merely restate base.
2. overlays/prd:
   - Must contain ONLY: kustomization.yaml pointing to ../../base
   - NO patchesStrategicMerge entries unless (rare) a future prod-only drift is intentionally introduced (document the reason inline).
3. overlays/dev:
   - Only environment that gets patches now.
   - Every patch file name must end with _dev.yaml.
4. If no diffs between dev and base: do NOT create a dev patch file for that resource.
5. NEVER create SealedSecret or IngressRoute patches in prd (base already authoritative).

Add this guard mentally before creating any patch:
IF target env == prod THEN abort patch creation.

## Patch Creation Flow (Dev Only)
For each resource in apps/{app}/base:
1. Diff against clusters/mlx-home-dev/{app or instance}/
2. If identical: skip.
3. If different: create apps/{app}/overlays/dev/{app}_{resource-kind}_dev.yaml
4. Add file under patchesStrategicMerge in overlays/dev/kustomization.yaml
5. Do not touch overlays/prd.

## App Migration Strategy
Each app has the PROD version coppied into `.\apps\{applicaiton}\base` already.

We need to create the patches that happen with the dev overlay, using the `patchesStrategicMerge` strategy

For each file in `.\apps\{applicaiton}\base`: 
1. reconcile against the same files in `.\clusters\mlx-home-dev\{application}`
   - If there are no notable changes, continue to next file
   - If there are notable changes, Create a file in `.apps\{application}\overlays\dev` for a patch
1. Update the `.apps\{application}\overlays\dev\kustomization.yaml` file with the patch

### Patching IngressRoute
All IngressRoutes should have a patch file.

IngressRoute patch requirements (strategic merge):
1. Always include: apiVersion, kind, metadata.name, metadata.namespace.
2. Always include the entire spec.routes list. Each route object must be reproduced fully (kind, match, services[], middlewares[], etc.).
3. Do NOT include spec.entryPoints (intentionally excluded).
4. If the base manifest contains spec.tls, COPY spec.tls into the patch verbatim (including certResolver, secretName, domains, options).  
   - If any tls field differs between environments, adjust it in the patch.  
   - If tls is absent in base, only add it if an environment actually introduces tls (then include the full tls object).
5. For any additional top-level spec children that differ (e.g., spec.services, spec.loadBalancer, spec.http, spec.tcp, spec.tls.options), include them fully in the patch.
6. Do not partially edit list items; replace or reproduce the full object.

IngressRoute patch checklist (tick mentally before committing):
- [ ] apiVersion/kind
- [ ] metadata.name / namespace
- [ ] spec.tls present? If yes in base, included verbatim (or intentionally updated)
- [ ] spec.routes full list (all routes, not partial)
- [ ] spec.entryPoints intentionally omitted
- [ ] Any other differing spec keys included

### Patching SealedSecret
All SealedSecret files should have a patch file

The patch file should update all of the `spec.encryptedData` fields only.

This is because different clusters will have different keys and encryption


### Quick Checklist (Run Before Committing Dev Overlay)
- [ ] No new files under overlays/prd other than kustomization.yaml
- [ ] All patch filenames end with _dev.yaml
- [ ] No prod (prd) patches created
- [ ] Each IngressRoute has a dev patch (even if only hostname/route changes)
- [ ] SealedSecret dev patch only changes spec.encryptedData
- [ ] HelmRelease patch only when values differ
- [ ] No pvc size changes
- [ ] spec.entryPoints omitted in IngressRoute patches
