#!/usr/bin/env python3
"""Guard rail for the two GitOps-contract delivery modes.

Each environment picks exactly one mode in contracts/delivery-mode.<env>:

  render  -> the cluster-identity values are rendered into committed Helm value
             files by scripts/render_gitops.py (values-<env>.generated.yaml for
             karpenter clusterName/queue and keycloak prod DB host).
  eso     -> External Secrets Operator materializes those values at runtime and
             the charts read them (values-<env>.eso.yaml).

The two are mutually exclusive per env. This script fails if, for any env, both
modes' value files are present, or the selected mode's files are missing / the
other mode's files leaked in.

Scope note: the Crossplane provider-sql manifests are NOT part of this toggle.
Their enumeration (which RDS instances exist) is inherently author-time, so they
stay contract-generated in both modes; their DB credentials already reach the
cluster via External Secrets regardless. See docs/gitops-contract-delivery-modes.md.

Stdlib only; safe to run in CI. Exit non-zero on any violation.
"""
import glob
import os
import sys

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
VALID_MODES = ("render", "eso")

# Charts whose per-env cluster-identity values the toggle governs. keycloak only
# has an external DB host in prod, so its eso file is required for prod only.
ESO_REQUIRED = {
    "karpenter": ("dev", "staging", "prod"),
    "keycloak": ("prod",),
}


def _mode_files():
    return sorted(glob.glob(os.path.join(REPO, "contracts", "delivery-mode.*")))


def _env_of(path):
    return os.path.basename(path).split(".", 1)[1]


def _read_mode(path):
    with open(path) as handle:
        return handle.read().strip()


def _generated_files(env):
    return sorted(glob.glob(os.path.join(REPO, "gitops", "infra", "*", f"values-{env}.generated.yaml")))


def _eso_files(env):
    return sorted(glob.glob(os.path.join(REPO, "gitops", "infra", "*", f"values-{env}.eso.yaml")))


def _rel(paths):
    return [os.path.relpath(p, REPO) for p in paths]


def check_env(path):
    env = _env_of(path)
    mode = _read_mode(path)
    if mode not in VALID_MODES:
        return [f"{env}: mode {mode!r} is not one of {VALID_MODES}"]

    generated = _generated_files(env)
    eso = _eso_files(env)
    errors = []

    if mode == "render":
        if eso:
            errors.append(f"{env}: mode is 'render' but eso value files exist: {_rel(eso)}")
    elif mode == "eso":
        if generated:
            errors.append(
                f"{env}: mode is 'eso' but render value files still exist: {_rel(generated)}. "
                f"Remove them so the two modes cannot both apply."
            )
        missing = [
            os.path.join(REPO, "gitops", "infra", chart, f"values-{env}.eso.yaml")
            for chart, envs in ESO_REQUIRED.items()
            if env in envs
        ]
        missing = [m for m in missing if not os.path.exists(m)]
        if missing:
            errors.append(f"{env}: mode is 'eso' but required value files are missing: {_rel(missing)}")
    return errors


def main():
    mode_files = _mode_files()
    if not mode_files:
        sys.exit("no contracts/delivery-mode.<env> files found")

    all_errors = []
    modes = {}
    for path in mode_files:
        modes[_env_of(path)] = _read_mode(path)
        all_errors.extend(check_env(path))

    if all_errors:
        print("delivery-mode guard rail FAILED:\n", file=sys.stderr)
        for err in all_errors:
            print(f"  - {err}", file=sys.stderr)
        sys.exit(1)

    for env, mode in sorted(modes.items()):
        print(f"ok: {env} -> {mode}")


if __name__ == "__main__":
    main()
