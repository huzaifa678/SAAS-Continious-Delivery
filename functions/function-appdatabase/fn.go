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

	"github.com/huzaifa678/function-appdatabase/input/v1beta1"
)

// sqlAPIVersion is the provider-sql (crossplane-contrib/provider-sql) API
// group/version for Role, Database, Grant and Extension.
const sqlAPIVersion = "postgresql.sql.crossplane.io/v1alpha1"

// Function composes the Postgres Role + Database + Grant (+ Extensions) for an
// XAppDatabase claim.
type Function struct {
	fnv1.UnimplementedFunctionRunnerServiceServer
	log logging.Logger
}

// RunFunction composes the provider-sql resources from the claim parameters.
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

	databaseName, _ := xr.GetString("spec.parameters.databaseName")
	owner, _ := xr.GetString("spec.parameters.owner")
	instance, _ := xr.GetString("spec.parameters.instance")
	if databaseName == "" || owner == "" || instance == "" {
		response.Fatal(rsp, errors.New("spec.parameters.databaseName, .owner and .instance are all required on the claim"))
		return rsp, nil
	}
	uid, _ := xr.GetString("metadata.uid")

	providerConfig := fmt.Sprintf(in.ProviderConfigFormat, instance)

	desired, err := request.GetDesiredComposedResources(req)
	if err != nil {
		response.Fatal(rsp, errors.Wrap(err, "cannot get desired composed resources"))
		return rsp, nil
	}

	// Compose the provider-sql Role, Database, Grant and Extensions from the claim parameters.
	role := composed.New()
	role.SetAPIVersion(sqlAPIVersion)
	role.SetKind("Role")
	prole := fieldpath.Pave(role.Object)
	must(prole.SetString("metadata.name", owner))
	must(prole.SetValue("spec.forProvider.privileges.login", true))
	must(prole.SetValue("spec.forProvider.privileges.createDb", false))
	must(prole.SetValue("spec.forProvider.privileges.createRole", false))
	must(prole.SetString("spec.providerConfigRef.name", providerConfig))
	must(prole.SetString("spec.writeConnectionSecretToRef.namespace", in.ConnectionSecretNamespace))
	must(prole.SetString("spec.writeConnectionSecretToRef.name", fmt.Sprintf("%s-role", uid)))
	desired[resource.Name("role")] = &resource.DesiredComposed{Resource: role}

	db := composed.New()
	db.SetAPIVersion(sqlAPIVersion)
	db.SetKind("Database")
	pdb := fieldpath.Pave(db.Object)
	must(pdb.SetString("metadata.name", databaseName))
	must(pdb.SetString("spec.forProvider.owner", owner))
	must(pdb.SetString("spec.providerConfigRef.name", providerConfig))
	desired[resource.Name("database")] = &resource.DesiredComposed{Resource: db}

	grant := composed.New()
	grant.SetAPIVersion(sqlAPIVersion)
	grant.SetKind("Grant")
	pgrant := fieldpath.Pave(grant.Object)
	must(pgrant.SetString("metadata.name", fmt.Sprintf("%s-owner-grant", databaseName)))
	must(pgrant.SetValue("spec.forProvider.privileges", []any{"ALL"}))
	must(pgrant.SetString("spec.forProvider.role", owner))
	must(pgrant.SetString("spec.forProvider.database", databaseName))
	must(pgrant.SetString("spec.providerConfigRef.name", providerConfig))
	desired[resource.Name("grant")] = &resource.DesiredComposed{Resource: grant}

	// Compose any requested provider-sql Extensions from the claim parameters.
	for _, ext := range getStringSlice(xr, "spec.parameters.extensions") {
		e := composed.New()
		e.SetAPIVersion(sqlAPIVersion)
		e.SetKind("Extension")
		pe := fieldpath.Pave(e.Object)
		must(pe.SetString("metadata.name", fmt.Sprintf("%s-%s", databaseName, ext)))
		must(pe.SetString("spec.forProvider.extension", ext))
		must(pe.SetString("spec.forProvider.database", databaseName))
		must(pe.SetString("spec.providerConfigRef.name", providerConfig))
		desired[resource.Name(fmt.Sprintf("extension-%s", ext))] = &resource.DesiredComposed{Resource: e}
	}

	if err := response.SetDesiredComposedResources(rsp, desired); err != nil {
		response.Fatal(rsp, errors.Wrap(err, "cannot set desired composed resources"))
		return rsp, nil
	}


	if obs, err := request.GetObservedComposedResources(req); err == nil {
		if r, ok := obs[resource.Name("role")]; ok {
			cd := resource.ConnectionDetails{}
			for src, dst := range map[string]string{"username": "username", "password": "password", "endpoint": "host"} {
				if v, ok := r.ConnectionDetails[src]; ok {
					cd[dst] = v
				}
			}
			cd["database"] = []byte(databaseName)
			if dxr, err := request.GetDesiredCompositeResource(req); err == nil {
				dxr.ConnectionDetails = cd
				_ = response.SetDesiredCompositeResource(rsp, dxr)
			}
		}
	}

	response.Normalf(rsp, "composed appdatabase %q owned by %q on instance %q (%s)", databaseName, owner, instance, providerConfig)
	f.log.Info("composed appdatabase", "database", databaseName, "owner", owner, "providerConfig", providerConfig)
	return rsp, nil
}

func setInputDefaults(in *v1beta1.Input) {
	if in.ProviderConfigFormat == "" {
		in.ProviderConfigFormat = "rds-%s"
	}
	if in.ConnectionSecretNamespace == "" {
		in.ConnectionSecretNamespace = "crossplane-system"
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

func must(err error) {
	if err != nil {
		panic(err)
	}
}
