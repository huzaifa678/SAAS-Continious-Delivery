package main

import rego.v1

approved_registry_suffixes := {"amazonaws.com", "ghcr.io", "quay.io", "docker.io"}

warn contains msg if {
	some c in all_containers
	image_tag(c.image) == "latest"
	msg := sprintf("%s: container %q uses the mutable :latest tag — pin an immutable tag/digest", [ref, c.name])
}

warn contains msg if {
	some c in all_containers
	has_no_tag(c.image)
	c.image != ""
	msg := sprintf("%s: container %q image %q has no explicit tag", [ref, c.name, c.image])
}

warn contains msg if {
	some c in all_containers
	c.image != ""
	not _from_approved_registry(c.image)
	msg := sprintf("%s: container %q image %q is not from an approved registry", [ref, c.name, c.image])
}

_from_approved_registry(image) if {
	registry := split(image, "/")[0]
	some suffix in approved_registry_suffixes
	endswith(registry, suffix)
}

warn contains msg if {
	some c in all_containers
	not c.resources.requests
	msg := sprintf("%s: container %q should set resources.requests (cpu/memory)", [ref, c.name])
}

warn contains msg if {
	some c in all_containers
	not c.resources.limits
	msg := sprintf("%s: container %q should set resources.limits (memory)", [ref, c.name])
}

warn contains msg if {
	some c in all_containers
	not c.securityContext.runAsNonRoot == true
	msg := sprintf("%s: container %q should set securityContext.runAsNonRoot: true", [ref, c.name])
}

warn contains msg if {
	some c in all_containers
	not c.securityContext.readOnlyRootFilesystem == true
	msg := sprintf("%s: container %q should set securityContext.readOnlyRootFilesystem: true", [ref, c.name])
}

warn contains msg if {
	some c in all_containers
	not c.securityContext.allowPrivilegeEscalation == false
	msg := sprintf("%s: container %q should set securityContext.allowPrivilegeEscalation: false", [ref, c.name])
}

warn contains msg if {
	some c in all_containers
	not c.livenessProbe
	msg := sprintf("%s: container %q should define a livenessProbe", [ref, c.name])
}

warn contains msg if {
	some c in all_containers
	not c.readinessProbe
	msg := sprintf("%s: container %q should define a readinessProbe", [ref, c.name])
}
