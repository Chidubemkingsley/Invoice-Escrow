---
name: Workspace dependency installation
description: Installing JavaScript dependencies in a nested pnpm artifact package
---

When installing JavaScript packages for one artifact in this pnpm monorepo, target it with `pnpm --filter @workspace/<artifact> add ...`; the generic package-install callback runs at the workspace root and cannot accept filter flags.

**Why:** An unscoped install was rejected as an unsafe root dependency change, and the installer also rejected `--filter` as a package token.

**How to apply:** Use the package-management callback first when it can target the right package; if it cannot, use pnpm with the artifact workspace filter rather than adding app dependencies to the root manifest.