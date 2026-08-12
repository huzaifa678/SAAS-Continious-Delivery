---
apiVersion: pkg.crossplane.io/v1
kind: Provider
metadata:
  name: provider-sql
  annotations:
    argocd.argoproj.io/sync-wave: "-1"
spec:
  package: xpkg.upbound.io/crossplane-contrib/provider-sql:v0.10.0
  packagePullPolicy: IfNotPresent
  revisionActivationPolicy: Automatic
  revisionHistoryLimit: 1
