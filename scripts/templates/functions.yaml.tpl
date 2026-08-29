---
# Composition Functions referenced by the XAppDatabase pipeline
# (platform/compositions/appdatabase-postgres.yaml). Installed at sync-wave "-1"
# — ahead of the XRD/Composition (implicit wave 0).
#
# function-appdatabase is our custom function (source: functions/function-appdatabase);
# its image lives in the account's ECR registry. The registry host below is
# rendered from the gitops contract's `registry.url`,
# see .github/workflows/build-function.yml.
apiVersion: pkg.crossplane.io/v1
kind: Function
metadata:
  name: function-appdatabase
  annotations:
    argocd.argoproj.io/sync-wave: "-1"
spec:
  package: __REGISTRY__/function-appdatabase:__FN_TAG__
  packagePullPolicy: IfNotPresent
  revisionActivationPolicy: Automatic
  revisionHistoryLimit: 1
---
apiVersion: pkg.crossplane.io/v1
kind: Function
metadata:
  name: function-auto-ready
  annotations:
    argocd.argoproj.io/sync-wave: "-1"
spec:
  package: xpkg.upbound.io/crossplane-contrib/function-auto-ready:v0.4.2
  packagePullPolicy: IfNotPresent
  revisionActivationPolicy: Automatic
  revisionHistoryLimit: 1
