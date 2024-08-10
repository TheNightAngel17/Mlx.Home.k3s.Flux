# Overview

I use `cloudflared` to expose services to the interwebs. To make this work with my current k3s services structure, I followed [this guid](https://developers.cloudflare.com/cloudflare-one/tutorials/many-cfd-one-tunnel/) on creating a deployment, and added a few tweaks. 

While i will not be saving my credentials to these files, i will be saving files here for the configurations

# Deployment

## Create a Tunnel

Ensure that you do this on a device that has access to your k3s cluster. You will need to take the credentials file and upload it as a secret via `kubectl`, and it is alot easier to do that on the same machine

1. Download and install [cloudflared](https://developers.cloudflare.com/cloudflare-one/connections/connect-networks/downloads/) to help with the creating and DNS set up

1. Login 
    ```
    cloudflared tunnel login
    ```

1. Create the tunnel
    ```
    cloudflared tunnel create mlx-home-k3s-dev
    ```
    ```
    cloudflared tunnel create mlx-home-k3s
    ```

1. Note the location that the credentials were written to.

## Prep Kubernetes For Deployment

1. Create new namespace
    ```
    kubectl create namespace cloudflared-tunnel
    ```

1. Upload Tunnel credentials to k3s as a secret
    ```
    kubectl create secret -n cloudflared-tunnel generic tunnel-credentials --from-file=credentials.json={{ path-to-file }}
    ```

## Associate DNS records

For each public service, you will need to create a new CNAME record in cloudflare to push requests through the tunnel. You can do that manually, or you can use the `cloudflared` cli to do so (preferred).
```
cloudflared tunnel route dns {{ tunnel-name }} {{ hostname }}
```

For example `cloudflared tunnel route dns mlx-home-k3s some-service.thelemonsclan.com`.

## Deploy `cloudflared`

Deploy config map and deployment.

```
kubectl apply -n cloudflared-tunnel -f mlx-home-k3s-dev.yml
```
# Helpful Commands

after any updates to the config, the service needs to be restarted to pick up the config.

1. Add new service hostname to DNS
    ```
    cloudflared tunnel route dns {{ tunnel-name }} {{ hostname }}
    ```

1. Restart the deplyment
    ```
    kubectl rollout restart deployments/cloudflared -n cloudflared-tunnel
    ```

