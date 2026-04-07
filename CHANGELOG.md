# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/).

## [Unreleased]

---

## 2026-04-07

### Added

- **LGTM observability stack** — new `02_monitoring` deployment stage (between `01_recovery` and `03_live`)
  - `apps/lgtm-prometheus/` — `kube-prometheus-stack` v72.x (Prometheus + embedded Grafana)
    - Grafana pre-configured with Loki and Tempo data sources
    - Pre-provisioned dashboards: node-exporter (#1860) and k8s-cluster (#7249)
    - Prometheus retention 7d, 10Gi Longhorn PVC; Grafana 2Gi Longhorn PVC
    - SealedSecrets for `grafana-admin-credentials` in both PRD (base) and DEV (overlay)
  - `apps/lgtm-loki/` — Loki v6.x, SingleBinary mode, filesystem backend, 10Gi Longhorn PVC
  - `apps/lgtm-tempo/` — Tempo v1.x, local trace backend, 5Gi Longhorn PVC
  - `apps/lgtm-alloy/` — Alloy v0.x; River config for pod log discovery → ships to Loki
  - `environments/{prd,dev}/02_monitoring/kustomization.yaml` — wires all four LGTM app overlays
  - `environments/{prd,dev}/namespaces/monitoring_Namespace.yaml` — `monitoring` namespace

### Changed

- `environments/prd/02_live` → `environments/prd/03_live` (renumbered to make room for monitoring stage)
- `environments/dev/02_live` → `environments/dev/03_live`
- `clusters/prd/kustomization.yaml` — `02_monitoring` commented out until verified in DEV; `02_live` ref updated to `03_live`
- `clusters/dev/kustomization.yaml` — `02_monitoring` active; `02_live` ref updated to `03_live`
- DEV and PRD now use identical Prometheus/Grafana sizing (dev-specific size patches removed)

---

## 2025-10-06

### Added

- helper scripts
   - `rename.ps1` - helps keep `apps/` file names consistent
   - `kubeseal/Rotate-SealedSecrets.*`
      - rotates sealed-secrets
      - cleans working directory
- Initial Changelog / tracking
- `.vscode/launch.json` items for eazy script running
- `.github/` items
   - PR Template
   - common prompt for copilot - `add-applicaiton.md`

### Changed

- Refactor to `apps/cluster/environments` w/ overlays from strictly `clusters`

### Removed

- Old `clusters/mlx-home-dev` reference
   > NOTE: keeping `clusters/mlx-home-prd` for 1 month following changes in the case we need to revert
