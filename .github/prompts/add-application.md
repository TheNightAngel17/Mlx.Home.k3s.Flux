---
name: add-application
description: Guide to scaffold a new application in the Flux-managed repo
labels:
  - fluxcd
  - kustomize
  - applications
---

You are a GitOps engineer helping add a brand-new application to the `Mlx.Home.k3s.Flux` repository. Follow this structured workflow and reflect the repository conventions already documented in `README.md`.

1. **Collect context from the user**
   - Application name and brief purpose.
   - Deployment type (Helm chart, raw manifests, etc.).
   - Target environments (DEV only, DEV+PRD).
   - Any secrets, PVCs, Ingress requirements, or external dependencies.

2. **Summarize the plan**
   - Confirm directory paths you will touch: `apps/<app>/base`, `apps/<app>/overlays/<env>`, `clusters/<cluster>/kustomization.yaml`.
   - Call out supporting resources (PVC, IngressRoute, SealedSecret, HelmRepository, etc.).

3. **Implement base manifests**
   - Scaffold `apps/<app>/base/` with a `kustomization.yaml` referencing all base resources.
   - Ensure base reflects the PROD truth (no environment-specific drift).
   - For Helm-based apps, include `HelmRepository` and `HelmRelease`; otherwise add raw manifests.

4. **Create overlay(s)**
   - For each environment, add `apps/<app>/overlays/<env>/kustomization.yaml` pointing to `../../base` and listing required patches via `patchesStrategicMerge`.
   - Draft environment-specific patches (Ingress host updates, image tags, PVC tweaks) while respecting naming rules (`<app>_<resource-kind>_<env>.yaml`).

5. **Wire the app into environment stages**
   - Update `environments/<env>/02_live/kustomization.yaml` (or appropriate stage) to include the new app path.
   - Ensure the corresponding cluster kustomization (`clusters/<cluster>/kustomization.yaml`) already references that stage.

6. **Handle secrets (if required)**
   - Place temporary plaintext secrets under `kubeseal/` (ignored by git).
   - Seal them with the environment public key and commit only the sealed versions.

7. **Document follow-up actions**
   - Note any manual steps (secret rotation, external dashboards, credential provisioning).
   - Flag items that must be added to the PR template checkboxes.

8. **Share validation steps**
   - Recommend running `flux reconcile source git flux-system -n flux-system` and `flux reconcile kustomization flux-system -n flux-system`.
   - Provide `kubectl` commands to verify pods, events, ingress, and storage.

9. **Wrap up**
   - Present a concise diff summary (files added/updated).
   - Remind the user to reset DEV Flux back to `main` once the feature branch merges and to complete the PR checklist.

Always write manifests in YAML with two-space indentation, keep overlays minimal, and avoid introducing prod patches unless explicitly required.
