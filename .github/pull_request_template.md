## Overview of Changes
- Summary: <!-- concise, imperative summary -->
- Related Issues: closes <issue-link> (optional)

<!-- Keep a Changelog notes -->
### Added

### Changed

### Deprecated

### Removed

### Fixed

### Security

## TODO during PR
- [ ] Feature branch deployed to DEV and verified.
   ```powershell
   kubectl patch gitrepository flux-system -n flux-system --type merge `
         -p '{"spec":{"ref":{"branch":"<branch-name>"}}}'
   ```
- [ ] Reconcile dev branch
   ```powershell
   flux reconcile source git flux-system -n flux-system
   flux reconcile kustomization flux-system -n flux-system
   ```
- [ ] Required manifests copied into `apps/*/base` and overlays adjusted.
- [ ] Secrets re-sealed with PROD keys when applicable.
- [ ] DEV Flux gitrepository reset to `main`.
   ```powershell
   kubectl patch gitrepository flux-system -n flux-system --type merge `
         -p '{"spec":{"ref":{"branch":"main"}}}'
   ```

## Verification & Testing
- [ ] Manual validation notes:
  - `kubectl get all -n <namespace>`
  - `kubectl logs deployment.apps/sealed-secrets -n kube-system`
  - `flux get kustomizations -n flux-system`
  - Additional checks: <!-- dashboards, smoke tests -->
- Application health checks 
   - [ ] Traefik routes functional
      ```powershell
      kubectl -n traefik port-forward pod/$(kubectl -n traefik get pods -l app.kubernetes.io/name=traefik -o jsonpath='{.items[0].metadata.name}') 8676:8080
      ```
   - [ ] Longhorn PVCs healthy
      ```powershell
      kubectl port-forward service/longhorn-frontend 8675:80 -n longhorn-system
      ```
   - [ ] Other (specify): 

## Dependencies / Follow-up
- Upstream PRs / modules: <!-- list or `None` -->
- Post-merge actions (secret rotation, cleanup jobs, migrations): <!-- details -->

## Documentation
- [ ] CHANGELOG updated
- [ ] README updated (if required).
- Notes: <!-- explain omissions -->

## Rollback Plan
- [ ] `git revert <commit-sha>` documented if needed.
- Fallback instructions: <!-- link to runbook or describe steps -->

## Screenshots / Logs (optional)
- <!-- attach screenshots, flux logs, kubectl output -->
