You are helping me refactor my GitOps repo for Flux.

# Current State
- I have 2 seperate folders for different environemtns of my cluster: `clusters/dev` and `clusters/prod`
- Each folder has subfolder(s) that pertain to specific applicaiton. E.g.
   - `/clusters/mlx-home-dev/bitwarden` contains bitwarden app details for dev
   - `/clusters/mlx-home-prd/bitwarden` contains bitwarden app details for prd
   - `/cluster/mlx-home-dev/mlx-charts` contains, for dev:
      - sub-folders for the different applicaitons 
      - even further sub-folders for seperate instances fo the application for `foundry-vtt`

## Current Setup Steps
On a freshly-installed kubernetes cluster, I:
1. install sealed secrets + import proper sealed secret
2. use flux bootstrap to bootstrap an init branch
   - this is a mirror to this branch, but only with namespace definitions + Longhorn installation
3. Do Data Recovory in Longhorn
4. use flux bootstrap to bootstrap this branch.


## Issues
This causes problems because
1. I really want to keep alot of the defiitions the same between them the best I can
2. Initalizing and maintaining seperate branches for the init steps is not fun

# Goal State
DO ALL CHANGES AS A COPY AND NOT A MOVE

we will be creating all net new files with the smae data for now. 

_**DO NOT TOUCH ANY FILES IN **_ `/clusters/mlx-homne-dev` _**OR**_ `/clusters/mlx-home-prd` _**OR**_ `README.md`

## Resource Definition Migrations
- All resource definitions that are needed already exist in the current folders with proper values
- Don't add any additional resource definitions
- Don't update any pvc sizes - use what's inside the file
- Don't update any versions and/or other values in release definitions
- Do keep all resource definitions the same.
- Do split definitions that differ into "patch" files per environment
   - e.g. pvc sizes
   - e.g. helm release values that differ
   - e.g. namespaces
- All namespaces are already applied correctly. For instanced items, they should have their own seperate namespaces.
- Currently shared items such as Helm Repos should be split into app-specific definitions in the off chance we want to move to a different definition
- Keep sealed secret encrypted data as it currently is.
- Only shared definitions for a cluster should be namespaces

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
- Files that have multiple instaces should be in the format of `{{app-name}}_{{instance}}_{{resource-kind}}_{{env}}.yaml`
   - same restrictions apply to these files as the generic applicaiton files

## App Definitions
- A new `/apps/` folder should be created where appls can be defined
- Each applicaiton type should have a subfolder under `/apps/`, like `/apps/bitwarden/` and `/apps/foundry-vtt/`
- each application should include a `base/` folder for common definitions that are the same for all environments
- each applicaiton should include a `overlays/{env}/` folder for each environment, defining patches or environment specific resources

## Cluster Definitions
- Under `/clusters`, i will have folder defintions for each environemtn of `/clusters/{env}/`
- Under each environment, there should be a `namespaces.yaml` file that includes all namespace definitions.
- Each environment will have 2 seperate folders/files
   - `init/kustomization.yaml` pointing to:
      - `../namespaces.yaml` to apply all namespaces
      - `../../../../apps/longhorn/overlays/{env}` to apply longhorn
   - `full/kustomization.yaml` pointing to:
      - `../namespaces.yaml` to apply all namespaces
      - multiple entries to apply all needed applications
         - e.g. `../../../../apps/{app}/overlays/{env}`
         - e.g. `../../../../apps/{app}/overlays/{instance}/{env}`

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
|   |           ├── kustomization.yaml
|   |           ├── applicaiton1_some-patch_prd.yaml
|   |           └── applicaiton1_sealedsecret_prd.yaml
|   ├── application2/
|   |   ├── base/
|   |   |   ├── kustomization.yaml
|   |   |   ├── applicaiton2_resource-definition1.yaml
|   |   |   ├── applicaiton2_resource-definition2.yaml
|   |   |   └── applicaiton2_resource-definition3.yaml
|   |   └── overlays/
|   |       ├── dev/
|   |       |   ├── kustomization.yaml
|   |       |   ├── applicaiton2_some-patch_dev.yaml
|   |       |   └── applicaiton2_sealedsecret_dev.yaml
|   |       └── prd/
|   |           ├── kustomization.yaml
|   |           ├── applicaiton2_some-patch_prd.yaml
|   |           └── applicaiton2_sealedsecret_prd.yaml
|   └── application3/
|       ├── base/
|       |   ├── kustomization.yaml
|       |   ├── applicaiton3_resource-definition1.yaml
|       |   ├── applicaiton3_resource-definition2.yaml
|       |   └── applicaiton3_resource-definition3.yaml
|       └── overlays/
|           ├── instance1/
|           |   ├── dev/
|           |   |   ├── kustomization.yaml
|           |   |   ├── applicaiton3_instance1_some-patch_dev.yaml
|           |   |   └── applicaiton3_instance1_sealedsecret_dev.yaml
|           |   └── prd/
|           |       ├── kustomization.yaml
|           |       ├── applicaiton3_instance1_some-patch_prd.yaml
|           |       └── applicaiton3_instance1_sealedsecret_prd.yaml
|           └── instance1/
|               ├── dev/
|               |   ├── kustomization.yaml
|               |   ├── applicaiton3_instance2_some-patch_dev.yaml
|               |   └── applicaiton3_instance2_sealedsecret_dev.yaml
|               └── prd/
|                   ├── kustomization.yaml
|                   ├── applicaiton3_instance2_some-patch_prd.yaml
|                   └── applicaiton3_instance2_sealedsecret_prd.yaml
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