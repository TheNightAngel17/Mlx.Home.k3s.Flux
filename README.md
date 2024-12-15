# Mlx.Home.k3s.Flux

MLX-Home Services are defined here in this Repo, along with all configurations and deployables for kubernetes. The rest of this README assumes we have a fresh-install of kubernetes (currently k3s), and we need to get our services up and running

# 1. Install Sealed-Secrets

Now, as there are a few services that require secrets, it got weird trying to have to manage what services needed secrets installed first or not. Then came along Sealed-Secrets.

## Overview of Sealed-Secrets

Long story short, you can take your plain-text yaml secrets, which can be easily decoded and viewed, run them throiug a `kubeseal` command, and have it spit out a similar file, but with the values for the secret sealed by encryption. This new object is of type `SealedSecret` instead of `Secret`, and when you apply it, kubernetes will see it, decode it, and apply it as a `Secret`.

## Setup Sealed-Secrets
In order for that to happen, we need to first initially set up the kubernetes cluster to:

1. Have the decoding service installed
2. Have it use the correct certificate(s) to decode the `SealedSecret`

To set up the decoding service, go to the [sealed-secrets releases page](https://github.com/bitnami-labs/sealed-secrets/releases), and look for the latest `sealed-secrets-v0.x.x`. On this release, there should be a copy-able link for `Cluster-side`. Copy it, and run it (a kubectl command)

```bash
kubectl apply -f https://github.com/bitnami-labs/sealed-secrets/releases/download/v0.x.x/controller.yaml
```

Once that is completed, apply the tls secret file. This file is located in a secured server (not in this reposiotry). You know where it is. If you don't, welp... have fun generating new secrets and such!!!

```bash
kubectl apply -f <file-name.yaml>
```

Once this has been applied, delete the other randomly-generated secret (`kubectl delete secret ...`), and restart the sealed-secrets-controller (`kubectl delete pod ...` ... this will restart the pod)


# 2. Prepare Flux

To handle the deployment of services, we utilize [Flux CD](https://fluxcd.io/), which is a way to declare services and configurations inside of code repositories, and when changes are made to the repository, corresponding changes happen in Kubernetes. The way one would do that is by bootstrapping the repository to the Flux Service, but using a `flux bootstrap` command. There are many different types of bootstrapping, which can be found on the [Flux Docs](https://fluxcd.io/flux/cmd/flux_bootstrap/), but we will be utilizing the generic GIT bootstrap, as to not tie us to a singlular service.

## Install Flux

In order to bootstrap with Flux, you will need to first have Flux installed. Follow the documentation in the [Flux Docs](https://fluxcd.io/flux/installation/) on how to install on whatever machine you are using.

## Create SSH Key

If, on the machine that you will be running Flux from, you don't have an SSH key set up to be able to connect to your git repository from, we will need to set one up. Currently, as we utilize GitHub, follow the instructions from [GitHub's Docs](https://docs.github.com/en/authentication/connecting-to-github-with-ssh/adding-a-new-ssh-key-to-your-github-account) on how to create & add a key to your account.

```bash
ssh-keygen -t ed25519 -C "29760146+TheNightAngel17@users.noreply.github.com" -f /home/lemonsml/.ssh/gh_flux_key -P ""
```

# 3. Data Reovory

As longhorn is our preferred storage class, we can use it to restore any backed-up data from our backup location. A part of the configuration of longhorn within this repository is to backup to an s3 site.

## Bootsrap Init Branch

First, we will need to bootstrap the `init` branch, which contains only longhorn configurations

```bash
flux bootstrap git --url=ssh://git@github.com/TheNightAngel17/Mlx.Home.k3s.Flux --branch=init --path=clusters/mlx-home-dev --private-key-file=/home/lemonsml/.ssh/gh_flux_key
```

```bash
flux bootstrap git --url=ssh://git@github.com/TheNightAngel17/Mlx.Home.k3s.Flux --branch=init --path=clusters/mlx-home-prd --private-key-file=/home/lemonsml/.ssh/gh_flux_key
```

## Access UI & restore

To restore backed-up volumes, you first need to access the UI. To do this, we will port-forward locally:

```bash
kubectl port-forward service/longhorn-frontend 8675:80 -n longhorn-system
```

Then we will access http://localhost:8675/#/dashboard, which will land us at the dashboard. From the dashboard, restore all backup volumes

# 4. Bootstrap the Full Repository

Next, we are ready to bootstrap the repository. It's as simple as running the `flux bootstrap` command.

```bash
flux bootstrap git --url=ssh://git@github.com/TheNightAngel17/Mlx.Home.k3s.Flux --branch=main --path=clusters/mlx-home-dev --private-key-file=/home/lemonsml/.ssh/gh_flux_key
```

```bash
flux bootstrap git --url=ssh://git@github.com/TheNightAngel17/Mlx.Home.k3s.Flux --branch=main --path=clusters/mlx-home-prd --private-key-file=/home/lemonsml/.ssh/gh_flux_key
```

after this has been boot-strapped, wait until all pods are ready

```bash
kubectl get pods --all-namespaces -o wide
```

# 3. Data Recovory
