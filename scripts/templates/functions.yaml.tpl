---
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
# Custom function composing the ElastiCache resources for XAppCache
# (source: functions/function-appcache), branching on the claim's mode.
apiVersion: pkg.crossplane.io/v1
kind: Function
metadata:
  name: function-appcache
  annotations:
    argocd.argoproj.io/sync-wave: "-1"
spec:
  package: __REGISTRY__/function-appcache:__FN_TAG__
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
