# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/).

## [Unreleased]

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
