package main

import rego.v1

_rollout(container) := {
	"kind": "Rollout",
	"metadata": {"name": "auth-service"},
	"spec": {"template": {"spec": {"containers": [container]}}},
}

_hardened := {
	"name": "auth-service",
	"image": "123.dkr.ecr.us-east-1.amazonaws.com/auth-service:v1.2.3",
	"resources": {"requests": {"cpu": "50m"}, "limits": {"memory": "256Mi"}},
	"livenessProbe": {"httpGet": {"path": "/healthz/live", "port": 8080}},
	"readinessProbe": {"httpGet": {"path": "/healthz/ready", "port": 8080}},
	"securityContext": {
		"runAsNonRoot": true,
		"readOnlyRootFilesystem": true,
		"allowPrivilegeEscalation": false,
	},
}

test_deny_privileged if {
	c := object.union(_hardened, {"securityContext": {"privileged": true}})
	count(deny) > 0 with input as _rollout(c)
}

test_deny_host_network if {
	count(deny) > 0 with input as {
		"kind": "Deployment",
		"metadata": {"name": "x"},
		"spec": {"template": {"spec": {"hostNetwork": true, "containers": [_hardened]}}},
	}
}

test_deny_net_raw if {
	c := object.union(_hardened, {"securityContext": {"capabilities": {"add": ["NET_RAW"]}}})
	count(deny) > 0 with input as _rollout(c)
}

test_hardened_rollout_no_deny if {
	count(deny) == 0 with input as _rollout(_hardened)
}

test_warn_latest_tag if {
	c := object.union(_hardened, {"image": "auth-service:latest"})
	count(warn) > 0 with input as _rollout(c)
}

test_warn_missing_resources if {
	c := {
		"name": "auth-service",
		"image": "123.dkr.ecr.us-east-1.amazonaws.com/auth-service:v1.2.3",
		"resources": {"requests": {"cpu": "50m"}},
		"livenessProbe": {"httpGet": {"path": "/healthz/live", "port": 8080}},
		"readinessProbe": {"httpGet": {"path": "/healthz/ready", "port": 8080}},
		"securityContext": {
			"runAsNonRoot": true,
			"readOnlyRootFilesystem": true,
			"allowPrivilegeEscalation": false,
		},
	}
	count(warn) > 0 with input as _rollout(c)
}

test_service_ignored if {
	count(deny) == 0 with input as {"kind": "Service", "metadata": {"name": "auth-service"}}
	count(warn) == 0 with input as {"kind": "Service", "metadata": {"name": "auth-service"}}
}
