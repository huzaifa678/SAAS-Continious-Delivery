// Package strict layers runtime-correctness constraints on top of #Values
// that don't translate to OpenAPI/JSON Schema. Used by `cue vet` in CI;
// not exported to Helm's values.schema.json.
package strict

import "github.com/huzaifa678/saas-continious-delivery/schemas/service"

#Values: service.#Values & {
	keda: {
		enabled: bool
		if enabled {
			minReplicaCount!: int & >=0
			maxReplicaCount!: int & >=1
			pollingInterval!: int & >0
			cooldownPeriod!:  int & >=0
			triggers!: [service.#KedaTrigger, ...service.#KedaTrigger]
		}
	}

	rollout: {
		steps: [_, ...] // at least one canary step required
		steps: [...#StrictStep]
		analysis: {
			enabled: bool
			if enabled {
				templates!: [{templateName!: string}, ...{templateName!: string}]
				interval!:               =~"^[0-9]+(ms|s|m|h)$"
				count!:                  int & >0
				failureLimit!:           int & >=0
				successRateThreshold!:   number & >=0 & <=1
				p95LatencyThresholdMs!:  int & >0
			}
		}
	}
}

// Each canary step must set exactly one of {setWeight, pause, setCanaryScale, analysis}.
// CUE disjunction enforces this at vet time; JSON Schema can't.
#StrictStep: {setWeight: int & >=0 & <=100} |
	{pause: {duration?: string | int}} |
	{setCanaryScale: {weight?: int, replicas?: int, matchTrafficWeight?: bool}} |
	{analysis: {
		templates!: [{templateName!: string}, ...{templateName!: string}]
		args?: [...{name!: string, value?: string, valueFrom?: {...}}]
	}}
