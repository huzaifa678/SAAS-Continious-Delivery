package service

#Values: {
	replicas!: int & >=0 & <=50
	port!:     int & >=1 & <=65535

	image!: #Image
	istio!: #Istio

	rollout!: #Rollout

	livenessProbe!:  #Probe
	readinessProbe!: #Probe

	circuitBreaking?: #CircuitBreaking

	keda!: #Keda

	// Optional: when present, the service requests a Postgres database via Crossplane.
	// Only services that own data need this block (e.g. usage-service).
	database?: #Database
}

#Database: {
	enabled!:      bool
	instance!:     "auth" | "billing" | "subscription" | "usage" | "keycloak"
	databaseName!: =~"^[a-z][a-z0-9_]{0,62}$"
	owner!:        =~"^[a-z][a-z0-9_]{0,62}$"
	extensions?: [...string]
}

#Image: {
	repository!: string
	tag!:        string & =~".+"
}

#Istio: {
	enabled!:  bool
	revision?: string
}

#Rollout: {
	revisionHistoryLimit?: int & >=0
	maxSurge?:             string | int
	maxUnavailable?:       string | int
	steps!: [...#RolloutStep]
	analysis!: #RolloutAnalysis
}

// Open struct — any combination of step keys may appear. Stricter "exactly one of"
// validation lives in schemas/service/strict and runs via `cue vet` in CI.
#RolloutStep: {
	setWeight?: int & >=0 & <=100
	pause?: {duration?: string | int}
	setCanaryScale?: {weight?: int, replicas?: int, matchTrafficWeight?: bool}
	analysis?: {
		templates?: [...{templateName?: string}]
		args?: [...{name?: string, value?: string, valueFrom?: {...}}]
	}
}

#RolloutAnalysis: {
	enabled!:               bool
	provider?:              "prometheus"
	startingStep?:          int & >=0
	templates?: [...{templateName!: string}]
	prometheusAddress?:     string
	interval?:              =~"^[0-9]+(ms|s|m|h)$"
	count?:                 int & >0
	failureLimit?:          int & >=0
	successRateThreshold?:  number & >=0 & <=1
	p95LatencyThresholdMs?: int & >0
}

#Probe: {
	path!:                string & =~"^/"
	initialDelaySeconds!: int & >=0
	periodSeconds!:       int & >0
}

#CircuitBreaking: {
	maxConnections?:           int & >0
	http1MaxPendingRequests?:  int & >0
	http2MaxRequests?:         int & >0
	maxRequestsPerConnection?: int & >0
	outlierDetection?: #OutlierDetection
}

#OutlierDetection: {
	consecutive5xxErrors?: int & >0
	interval?:             =~"^[0-9]+(ms|s|m|h)$"
	baseEjectionTime?:     =~"^[0-9]+(ms|s|m|h)$"
	maxEjectionPercent?:   int & >=0 & <=100
}

#Keda: {
	enabled!:         bool
	minReplicaCount?: int & >=0
	maxReplicaCount?: int & >=1
	pollingInterval?: int & >0
	cooldownPeriod?:  int & >=0
	fallback?: {...}
	advanced?: {...}
	triggers?: [...#KedaTrigger]
}

#KedaTrigger: {
	type!:       string & =~".+"
	metricType?: "Utilization" | "AverageValue" | "Value"
	metadata?: [string]: string
	name?: string
}

