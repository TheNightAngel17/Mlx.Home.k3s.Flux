## Overview of Changes
- Summary: <!-- concise, imperative summary -->
- Related Issues: closes <issue-link> (optional)
- Notable Impact: <!-- breaking changes, prod-only impact -->

## Testing
- [ ] Automated tests (list suites or `N/A`)
- [ ] Manual validation notes:
  - `kubectl get kustomizations -A`
  - `flux get kustomizations -n flux-system`
  - Additional checks: <!-- dashboards, smoke tests -->

## Summary
- [ ] Feature branch deployed to DEV and verified.
- [ ] Required manifests copied into `apps/*/base` and overlays adjusted.
- [ ] Secrets re-sealed with PROD keys when applicable.
- [ ] DEV Flux gitrepository reset to `main`.

## Verification
- [ ] `flux reconcile source git flux-system -n flux-system`
- [ ] `flux reconcile kustomization flux-system -n flux-system`
- [ ] Application health checks (Traefik routes, Longhorn PVCs, namespace pods) confirmed.

## Dependencies / Follow-up
- Upstream PRs / modules: <!-- list or `None` -->
- Post-merge actions (secret rotation, cleanup jobs, migrations): <!-- details -->

## Documentation
- [ ] README updated (if required).
- [ ] Runbooks / dashboards updated (if required).
- Notes: <!-- explain omissions -->

## Rollback Plan
- [ ] `git revert <commit-sha>` documented if needed.
- Fallback instructions: <!-- link to runbook or describe steps -->

## Screenshots / Logs (optional)
- <!-- attach screenshots, flux logs, kubectl output -->
