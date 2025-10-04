You are an automation assitant helping me create an automation script to rotate encrypted data.

# Overview
The premise of your goal is to help me generate a powershell script that automates the rotation of sealedsecret values.

The shell script should be in `.\kubeseal` 

the script will:
1. Validate parameters and capabilities of the system
1. Cleanup old run data
1. Generate new sealing keys
1. Create local coppies of SealedSecret files, including environment specific patches using `patchesStrategicMerge:` strategy
1. Unseal all coppied SealedSecrets using the existing private-key
1. Seal all unsealed secrets using newly generated keys
1. Recopy sealed data back to the `./apps` folder, including possible updates for patches using `patchesStrategicMerge:`

# Parameters

## Main usage
1. `env` / `-e`: What environment to run for
   - dev
   - prd
   - other options not available
1. `key` / `-k`: the private key file for the current cert
   - string, free-text
   - should be able to pass in a path to a key, for example `.\dev\mlx-home-dev-sealedsecret.key`
1. `algorithm` / `-a`: What algorithm to use for openssl key generation
   - RSA4096
   - Ed25519

## Cleanup
1. `env` / `-e`: What environemnt folders to look at
   - dev
   - prd
   - other options are not available
1. `clean` / `-c`: flag to clean

## Help
1. `help` / `-h`
   - Flag that prints the script help information and exits.
   - flag that says we should clean the working subfolders




# Process Steps
1. Validation
   1. Verify that the following items are installed (generally via Chocolaty):
      > NOTE: do not install it, just verify they are available and if not, output a message saying to install them
      - openssl
      - kubeseal
   1. Verify that the current cert private key exist
      - The current cert private key should exist in the approprate folder based on `$env`
      - e.g. if we passed in dev and testing.key, we should ensure that `./kubeseal/dev/testing.key` exists
1. Cleanup working subfolders
   - working subfolders are:
      - `./kubeseal/{{$env}}/00_sealed/`
      - `./kubeseal/{{$env}}/01_unsealed/`
      - `./kubeseal/{{$env}}/02_resealed/`
   - If we are flagged for cleaning only, that's all we need to do, can exit the script
1. Create a local variable for file name names (cert + yaml)
   - `{{$env}}_{{yyyyMMdd}}_{{hhmmss}}_{{$new-algorithm}}_Secret`
1. generate the `.crt` and the `.key` files 
   - using the correct `$new-algorithm` type
   - files are dropped in the folder that the `-CurrentCertPrivateKey` is grabgbed from 
      - if no direct path given, default to assiming the key is in the appropriate `$env` directory
      - e.g. new certs for dev using RSA4096 with current key being `C:/secrets/my-key.key`:
         - `C:/secrets/dev_20250928_193000_RSA4096_Secret.crt` for public key
         - `C:/secrets/dev_20250928_193000_RSA4096_Secret.key` for private key
1. Create a new SealedSecret file with the newly generated encryption key data
   - create a new SealedSecrets file `{{original-key-path}}/dev_20250928_193000_RSA4096_Secret.yaml`
   - contents:
      ```yaml
      apiVersion: v1  
      kind: Secret
      type: kubernetes.io/tls
      metadata:
        name: sealed-secrets-keyvhrp4
        namespace: kube-system  
      data:
        tls.crt: {{base-64-encoded-cert}}
        tls.key: {{base-64-encoded-private-key}}
      ```
1. Copy all current sealed-secrets for apps for the specific `$.env`
   - The location for the coppies are `./kubeseal/{{$env}}/00_sealed/`
   - All apps live inside of `./apps/` folder
   - The folder structure is such that:
      - subfolders of `./apps/` represent an applicaiton
      - Inside of the applicaiton folder, there is a `base/` and `overlays/` folders
         - The `base/` folder has all definitions used by all environments
         - The `overlays/` folder has per-environment folders with patches to files in the `base/` file using `patchesStrategicMerge:` methods
         - Generally (but not always) `overlays/prd/` is just a redirect to `base/` and `base/` has all prod files
         - It should be that if an app has a SealedSecret in `base/`, any other environment other than prd should have a seperate patch for SealedSecrets, updating the `spec.encryptedData` node
   - all sealed secret files inside of an app should have `_SealedSecret` in the name of the file
   - Assume the SealedSecret defintion is the only item in that file
   - Apply any changes to environment specific overlays to the coppied file
      - overlays for sealed secrets are in files that are named EXACTLY the same in `base/` as they are in `overlays/{{env}}/`
      - e.g. if theres an `.\apps\app1\base\app1_SealedSecret.yaml` and a `.\apps\app1\overlays\dev\appp1_SealedSecret_dev.yaml`, apply the changes to `spec.encryptedData` to the coppied file from `.\apps\app1\base`
   - keep a mapping of the file name to it's location and how it needs to be update for use in the last step
1. Unseal all sealed secrets 
   - Output directory of unsealed secrets is `./kubeseal/{{$env}}/01_unsealed/`
   - rename the output file:
      - go from `{{app-name}}_SealedSecret.yaml` to `{{app-name}}_Secret.yaml`
      - basically replacing `_SealedSecret` to `_Secret` in the file name
   - ensure we are using yaml format in the unseal command
   - ensure we are passing in the currently existing key for unsealing
   - command should be something like `kubeseal --format=yaml --recovery-unseal --recovery-private-key {{$current-cert-private-key}} < {{sealedsecret-file-name}} > {{unsealed-secret-target-file-name}}`
1. reseal all unsealed secrets
   - Output directory of resealed secrets is `./kubeseal/{{$env}}/02_resealed/`
   - rename the output file:
      - go from `{{app-name}}_Secret.yaml` to `{{app-name}}_SealedSecret.yaml`
      - basically replacing `_Secret` with `_SealedSecret` in the file name
   - ensure we are using yaml format in the unseal command
   - ensure we are passing in the newly generated key for sealing
   - command should be something like `kubeseal --format=yaml --cert {{newly-generated-public-key}} < {{unsealed-secret-file-name}} > {{resealed-secret-target-file-name}}`
1. Copy all re-sealed secret data back to `./apps` folder
   - Must be aware of if data was originally gotten from a patch file or from base
   - If it was from a patch file, only update the `spec.encryptedData` in the new file
      - the subnodes *should* all be the same, just with different values after resealing


