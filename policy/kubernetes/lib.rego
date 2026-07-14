package main

import rego.v1

pod_workload_kinds := {
	"Deployment",
	"StatefulSet",
	"DaemonSet",
	"ReplicaSet",
	"Job",
	"Rollout",
}

is_pod_workload if input.kind in pod_workload_kinds

pod_spec := input.spec.template.spec

# All app + init containers of the current workload.
all_containers contains c if {
	is_pod_workload
	some c in pod_spec.containers
}

all_containers contains c if {
	is_pod_workload
	some c in object.get(pod_spec, "initContainers", [])
}

kind := input.kind

name := object.get(input, ["metadata", "name"], "<unnamed>")

ref := sprintf("%s/%s", [kind, name])

image_tag(image) := tag if {
	parts := split(image, ":")
	count(parts) > 1
	tag := parts[count(parts) - 1]
}

has_no_tag(image) if not contains(image, ":")
