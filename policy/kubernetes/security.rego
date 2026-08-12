package main

import rego.v1

# Sanctioned node/system agents (node-exporter, promtail, elasticsearch sysctl
# init) legitimately need host access. They carry this annotation, applied only
# to the specific workloads via each addon's Kustomize post-renderer — an
# auditable, per-workload exemption rather than a blanket namespace waiver.
allow_host_access if input.metadata.annotations["policy.saas.io/allow-host-access"] == "true"

deny contains msg if {
	not allow_host_access
	some c in all_containers
	c.securityContext.privileged == true
	msg := sprintf("%s: container %q must not run privileged", [ref, c.name])
}

deny contains msg if {
	not allow_host_access
	is_pod_workload
	pod_spec.hostNetwork == true
	msg := sprintf("%s: hostNetwork=true is not allowed", [ref])
}

deny contains msg if {
	not allow_host_access
	is_pod_workload
	pod_spec.hostPID == true
	msg := sprintf("%s: hostPID=true is not allowed", [ref])
}

deny contains msg if {
	not allow_host_access
	is_pod_workload
	pod_spec.hostIPC == true
	msg := sprintf("%s: hostIPC=true is not allowed", [ref])
}

deny contains msg if {
	not allow_host_access
	is_pod_workload
	some v in object.get(pod_spec, "volumes", [])
	v.hostPath
	msg := sprintf("%s: hostPath volume %q is not allowed", [ref, v.name])
}

deny contains msg if {
	not allow_host_access
	some c in all_containers
	c.securityContext.runAsUser == 0
	msg := sprintf("%s: container %q must not run as root (runAsUser: 0)", [ref, c.name])
}

dangerous_caps := {"ALL", "NET_RAW", "NET_ADMIN", "SYS_ADMIN", "SYS_PTRACE", "SYS_MODULE"}

deny contains msg if {
	some c in all_containers
	some cap in object.get(c.securityContext, ["capabilities", "add"], [])
	upper(cap) in dangerous_caps
	msg := sprintf("%s: container %q adds dangerous capability %q", [ref, c.name, cap])
}
