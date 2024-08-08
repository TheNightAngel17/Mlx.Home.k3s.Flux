# Overview

We will be deploying bitwarden via a helm chart, using 

# Prep (secrets)

1. create namespace
    ```
    kubectl create namespace bitwarden
    ```

1. create secret, filling out values appropriatly
    ```
    kubectl create secret generic bitwarden-secret -n bitwarden-dev --from-literal=globalSettings__installation__id="" --from-literal=globalSettings__installation__key="" --from-literal=globalSettings__mail__smtp__username="" --from-literal=globalSettings__mail__smtp__password="" --from-literal=globalSettings__yubico__clientId="" --from-literal=globalSettings__yubico__key="" --from-literal=globalSettings__hibpApiKey="" --from-literal=SA_PASSWORD=""
    ```

1. Profit