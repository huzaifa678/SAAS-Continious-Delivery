package main

import (
	"context"
	"fmt"

	"github.com/crossplane/crossplane-runtime/pkg/errors"
	"github.com/crossplane/crossplane-runtime/pkg/fieldpath"

	"github.com/crossplane/function-sdk-go/logging"
	fnv1 "github.com/crossplane/function-sdk-go/proto/v1"
	"github.com/crossplane/function-sdk-go/request"
	"github.com/crossplane/function-sdk-go/resource"
	"github.com/crossplane/function-sdk-go/resource/composed"
	"github.com/crossplane/function-sdk-go/response"

	"github.com/huzaifa678/function-appcache/input/v1beta1"
)

// ecAPIVersion is the provider-aws (Upbound) ElastiCache API group/version for
// User, UserGroup and ReplicationGroup.
const ecAPIVersion = "elasticache.aws.upbound.io/v1beta1"

const (
	// tenantGroupLabel is what the platform UserGroup selects shared-mode tenant
	// users on (platform/appcache/redis-tenant-usergroup.yaml).
	tenantGroupLabel = "platform.saas.example/redis-tenant-group"
	prefixAnnotation = "platform.saas.example/prefix"
	externalNameAnno = "crossplane.io/external-name"
)

// Function composes the ElastiCache resources for an XAppCache claim.
type Function struct {
	fnv1.UnimplementedFunctionRunnerServiceServer
	log logging.Logger
}

// RunFunction composes the provider-aws resources from the claim parameters,
// branching on spec.parameters.mode.
func (f *Function) RunFunction(_ context.Context, req *fnv1.RunFunctionRequest) (*fnv1.RunFunctionResponse, error) {
	rsp := response.To(req, response.DefaultTTL)

	in := &v1beta1.Input{}
	if err := request.GetInput(req, in); err != nil {
		response.Fatal(rsp, errors.Wrap(err, "cannot get Function input"))
		return rsp, nil
	}
	setInputDefaults(in)

	oxr, err := request.GetObservedCompositeResource(req)
	if err != nil {
		response.Fatal(rsp, errors.Wrap(err, "cannot get observed composite resource"))
		return rsp, nil
	}
	xr := fieldpath.Pave(oxr.Resource.Object)

	serviceName, _ := xr.GetString("spec.parameters.serviceName")
	if serviceName == "" {
		response.Fatal(rsp, errors.New("spec.parameters.serviceName is required on the claim"))
		return rsp, nil
	}
	mode := getStringOr(xr, "spec.parameters.mode", "shared")
	keyPrefix := getStringOr(xr, "spec.parameters.keyPrefix", serviceName)
	region := getStringOr(xr, "spec.parameters.region", "us-east-1")

	desired, err := request.GetDesiredComposedResources(req)
	if err != nil {
		response.Fatal(rsp, errors.Wrap(err, "cannot get desired composed resources"))
		return rsp, nil
	}

	switch mode {
	case "shared":
		userGroupID := getStringOr(xr, "spec.parameters.userGroupId", in.DefaultUserGroupID)
		composeShared(desired, in, serviceName, keyPrefix, region, userGroupID)
	case "dedicated":
		composeDedicated(desired, xr, in, serviceName, keyPrefix, region)
	default:
		response.Fatal(rsp, errors.Errorf("unknown mode %q; want shared or dedicated", mode))
		return rsp, nil
	}

	if err := response.SetDesiredComposedResources(rsp, desired); err != nil {
		response.Fatal(rsp, errors.Wrap(err, "cannot set desired composed resources"))
		return rsp, nil
	}

	// Publish the tenant identity (and, for a dedicated cluster, its endpoint)
	// onto the XR connection secret. In shared mode the host is the platform's
	// shared Redis, delivered separately by the gitops-contract redis secret.
	cd := resource.ConnectionDetails{
		"username": []byte(serviceName),
		"prefix":   []byte(keyPrefix),
	}
	if mode == "dedicated" {
		if host := observedClusterEndpoint(req); host != "" {
			cd["host"] = []byte(host)
			cd["port"] = []byte("6379")
		}
	}
	if dxr, err := request.GetDesiredCompositeResource(req); err == nil {
		dxr.ConnectionDetails = cd
		_ = response.SetDesiredCompositeResource(rsp, dxr)
	}

	response.Normalf(rsp, "composed appcache %q in %q mode (prefix %q)", serviceName, mode, keyPrefix)
	f.log.Info("composed appcache", "service", serviceName, "mode", mode, "prefix", keyPrefix)
	return rsp, nil
}

// composeShared composes one IAM-authed ACL user scoped to ~<prefix>:*, labelled
// so the platform user group aggregates it onto the shared cluster.
func composeShared(desired map[resource.Name]*resource.DesiredComposed, in *v1beta1.Input, serviceName, keyPrefix, region, userGroupID string) {
	u := newUser(in, serviceName, region, fmt.Sprintf("on ~%s:* resetchannels +@all -@dangerous", keyPrefix))
	p := fieldpath.Pave(u.Object)
	must(p.SetString("metadata.annotations["+externalNameAnno+"]", serviceName))
	must(p.SetString("metadata.labels["+tenantGroupLabel+"]", userGroupID))
	must(p.SetString("metadata.annotations["+prefixAnnotation+"]", keyPrefix))
	desired[resource.Name("acl-user")] = &resource.DesiredComposed{Resource: u}
}

// composeDedicated composes the service's own ReplicationGroup (cluster-mode
// capable) plus a private RBAC user group (disabled default + app user).
func composeDedicated(desired map[resource.Name]*resource.DesiredComposed, xr *fieldpath.Paved, in *v1beta1.Input, serviceName, keyPrefix, region string) {
	nodeType := getStringOr(xr, "spec.parameters.nodeType", "cache.t4g.medium")
	subnetGroup := getStringOr(xr, "spec.parameters.subnetGroupName", "saas-redis-subnet-group")
	kmsKeyID := getStringOr(xr, "spec.parameters.kmsKeyId", "")
	numShards := getIntOr(xr, "spec.parameters.numShards", 1)
	numReplicas := getIntOr(xr, "spec.parameters.numReplicas", 1)
	sgIDs := getStringSlice(xr, "spec.parameters.securityGroupIds")

	// AWS requires the group to hold a `default` user; keep it disabled.
	def := newUser(in, serviceName+"-cache-default", region, "off -@all")
	must(fieldpath.Pave(def.Object).SetString("metadata.annotations["+externalNameAnno+"]", serviceName+"-cache-default"))
	desired[resource.Name("default-user")] = &resource.DesiredComposed{Resource: def}

	app := newUser(in, serviceName, region, "on ~* resetchannels +@all -@dangerous")
	pa := fieldpath.Pave(app.Object)
	must(pa.SetString("metadata.annotations["+externalNameAnno+"]", serviceName))
	must(pa.SetString("metadata.annotations["+prefixAnnotation+"]", keyPrefix))
	desired[resource.Name("app-user")] = &resource.DesiredComposed{Resource: app}

	ug := composed.New()
	ug.SetAPIVersion(ecAPIVersion)
	ug.SetKind("UserGroup")
	pug := fieldpath.Pave(ug.Object)
	must(pug.SetString("metadata.annotations["+externalNameAnno+"]", serviceName+"-cache"))
	must(pug.SetString("spec.forProvider.engine", "redis"))
	// matchControllerRef binds the two sibling User MRs owned by this XR.
	must(pug.SetValue("spec.forProvider.userIdsSelector.matchControllerRef", true))
	must(pug.SetString("spec.forProvider.region", region))
	must(pug.SetString("spec.providerConfigRef.name", in.ProviderConfigName))
	desired[resource.Name("user-group")] = &resource.DesiredComposed{Resource: ug}

	rg := composed.New()
	rg.SetAPIVersion(ecAPIVersion)
	rg.SetKind("ReplicationGroup")
	prg := fieldpath.Pave(rg.Object)
	must(prg.SetString("metadata.annotations["+externalNameAnno+"]", serviceName+"-cache"))
	must(prg.SetString("spec.forProvider.engine", "redis"))
	must(prg.SetString("spec.forProvider.engineVersion", "7.0"))
	must(prg.SetString("spec.forProvider.description", "Dedicated Redis for a SAAS service (AppCache)"))
	must(prg.SetValue("spec.forProvider.port", 6379))
	must(prg.SetValue("spec.forProvider.atRestEncryptionEnabled", true))
	must(prg.SetValue("spec.forProvider.transitEncryptionEnabled", true))
	must(prg.SetValue("spec.forProvider.automaticFailoverEnabled", true))
	must(prg.SetValue("spec.forProvider.multiAzEnabled", true))
	must(prg.SetString("spec.forProvider.nodeType", nodeType))
	must(prg.SetValue("spec.forProvider.numNodeGroups", numShards))
	must(prg.SetValue("spec.forProvider.replicasPerNodeGroup", numReplicas))
	must(prg.SetString("spec.forProvider.subnetGroupName", subnetGroup))
	if len(sgIDs) > 0 {
		must(prg.SetValue("spec.forProvider.securityGroupIds", toAnySlice(sgIDs)))
	}
	if kmsKeyID != "" {
		must(prg.SetString("spec.forProvider.kmsKeyId", kmsKeyID))
	}
	must(prg.SetValue("spec.forProvider.userGroupIdsSelector.matchControllerRef", true))
	must(prg.SetString("spec.forProvider.region", region))
	must(prg.SetString("spec.providerConfigRef.name", in.ProviderConfigName))
	desired[resource.Name("replication-group")] = &resource.DesiredComposed{Resource: rg}
}

// newUser returns a provider-aws ElastiCache User (IAM auth) with the given
// access string.
func newUser(in *v1beta1.Input, userName, region, accessString string) *composed.Unstructured {
	u := composed.New()
	u.SetAPIVersion(ecAPIVersion)
	u.SetKind("User")
	p := fieldpath.Pave(u.Object)
	must(p.SetString("spec.forProvider.engine", "redis"))
	must(p.SetString("spec.forProvider.userName", userName))
	must(p.SetString("spec.forProvider.accessString", accessString))
	must(p.SetValue("spec.forProvider.authenticationMode", []any{map[string]any{"type": "iam"}}))
	must(p.SetString("spec.forProvider.region", region))
	must(p.SetString("spec.providerConfigRef.name", in.ProviderConfigName))
	return u
}

// observedClusterEndpoint returns the dedicated cluster's endpoint once the
// ReplicationGroup has reconciled — the configuration endpoint in cluster mode,
// otherwise the primary endpoint.
func observedClusterEndpoint(req *fnv1.RunFunctionRequest) string {
	obs, err := request.GetObservedComposedResources(req)
	if err != nil {
		return ""
	}
	r, ok := obs[resource.Name("replication-group")]
	if !ok {
		return ""
	}
	p := fieldpath.Pave(r.Resource.Object)
	if v, err := p.GetString("status.atProvider.configurationEndpointAddress"); err == nil && v != "" {
		return v
	}
	if v, err := p.GetString("status.atProvider.primaryEndpointAddress"); err == nil && v != "" {
		return v
	}
	return ""
}

func setInputDefaults(in *v1beta1.Input) {
	if in.ProviderConfigName == "" {
		in.ProviderConfigName = "aws-elasticache"
	}
	if in.DefaultUserGroupID == "" {
		in.DefaultUserGroupID = "saas-redis"
	}
}

func getStringOr(p *fieldpath.Paved, path, def string) string {
	if v, err := p.GetString(path); err == nil && v != "" {
		return v
	}
	return def
}

func getIntOr(p *fieldpath.Paved, path string, def int) int {
	v, err := p.GetValue(path)
	if err != nil || v == nil {
		return def
	}
	switch n := v.(type) {
	case float64:
		return int(n)
	case int64:
		return int(n)
	case int:
		return n
	default:
		return def
	}
}

// getStringSlice reads a []string claim parameter, tolerating the []any shape
// values arrive in through structpb.
func getStringSlice(p *fieldpath.Paved, path string) []string {
	v, err := p.GetValue(path)
	if err != nil || v == nil {
		return nil
	}
	raw, ok := v.([]any)
	if !ok {
		return nil
	}
	out := make([]string, 0, len(raw))
	for _, item := range raw {
		if s, ok := item.(string); ok && s != "" {
			out = append(out, s)
		}
	}
	return out
}

func toAnySlice(ss []string) []any {
	out := make([]any, len(ss))
	for i, s := range ss {
		out[i] = s
	}
	return out
}

func must(err error) {
	if err != nil {
		panic(err)
	}
}
