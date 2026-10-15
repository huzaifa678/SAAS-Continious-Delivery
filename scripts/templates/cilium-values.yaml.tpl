# k8sServiceHost for kube-proxy replacement, from the Terraform gitops_contract
# (cluster.eks_api_endpoint, scheme/port stripped to a bare host by the renderer).
# Nested under `cilium:` because gitops/infra/cilium is an umbrella chart whose
# only content is the `cilium` subchart — Helm passes values down only when they
# are keyed by the subchart name; a top-level key here is silently ignored.
cilium:
  k8sServiceHost: __EKS_API_ENDPOINT__
