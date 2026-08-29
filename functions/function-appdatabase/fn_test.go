package main

import (
	"context"
	"testing"

	"github.com/crossplane/function-sdk-go/logging"
	"google.golang.org/protobuf/types/known/structpb"

	fnv1 "github.com/crossplane/function-sdk-go/proto/v1"
)

func mustStruct(t *testing.T, m map[string]any) *structpb.Struct {
	t.Helper()
	s, err := structpb.NewStruct(m)
	if err != nil {
		t.Fatalf("structpb.NewStruct: %v", err)
	}
	return s
}

func forProvider(t *testing.T, res *fnv1.Resource) map[string]*structpb.Value {
	t.Helper()
	return res.GetResource().GetFields()["spec"].GetStructValue().
		GetFields()["forProvider"].GetStructValue().GetFields()
}

// TestRunFunction_ComposesRoleDatabaseGrant asserts the three core provider-sql
// resources are composed with the expected names, owner and ProviderConfig.
func TestRunFunction_ComposesRoleDatabaseGrant(t *testing.T) {
	xr := mustStruct(t, map[string]any{
		"apiVersion": "platform.saas.example/v1alpha1",
		"kind":       "XAppDatabase",
		"metadata":   map[string]any{"uid": "uid-1234"},
		"spec": map[string]any{
			"parameters": map[string]any{
				"databaseName": "billing",
				"owner":        "billing_app",
				"instance":     "billing",
			},
		},
	})
	req := &fnv1.RunFunctionRequest{Observed: &fnv1.State{Composite: &fnv1.Resource{Resource: xr}}}

	f := &Function{log: logging.NewNopLogger()}
	rsp, err := f.RunFunction(context.Background(), req)
	if err != nil {
		t.Fatalf("RunFunction returned error: %v", err)
	}

	res := rsp.GetDesired().GetResources()
	for _, name := range []string{"role", "database", "grant"} {
		if _, ok := res[name]; !ok {
			t.Fatalf("expected a desired %q; got %v", name, keysOfResources(res))
		}
	}

	// Role: named after the owner, wired to ProviderConfig rds-billing.
	if got := res["role"].GetResource().GetFields()["metadata"].GetStructValue().GetFields()["name"].GetStringValue(); got != "billing_app" {
		t.Errorf("role metadata.name = %q, want billing_app", got)
	}
	if got := providerConfigName(res["role"]); got != "rds-billing" {
		t.Errorf("role providerConfigRef.name = %q, want rds-billing", got)
	}

	// Database: owned by the role.
	if got := forProvider(t, res["database"])["owner"].GetStringValue(); got != "billing_app" {
		t.Errorf("database forProvider.owner = %q, want billing_app", got)
	}

	// Grant: <db>-owner-grant with ALL on the database to the role.
	if got := res["grant"].GetResource().GetFields()["metadata"].GetStructValue().GetFields()["name"].GetStringValue(); got != "billing-owner-grant" {
		t.Errorf("grant metadata.name = %q, want billing-owner-grant", got)
	}
	gp := forProvider(t, res["grant"])
	if got := gp["database"].GetStringValue(); got != "billing" {
		t.Errorf("grant forProvider.database = %q, want billing", got)
	}
	privs := gp["privileges"].GetListValue().GetValues()
	if len(privs) != 1 || privs[0].GetStringValue() != "ALL" {
		t.Errorf("grant privileges = %v, want [ALL]", privs)
	}
}

// TestRunFunction_ComposesExtensions asserts an Extension is composed per
// requested extension (behaviour the old YAML composition lacked).
func TestRunFunction_ComposesExtensions(t *testing.T) {
	xr := mustStruct(t, map[string]any{
		"apiVersion": "platform.saas.example/v1alpha1",
		"kind":       "XAppDatabase",
		"metadata":   map[string]any{"uid": "uid-1"},
		"spec": map[string]any{
			"parameters": map[string]any{
				"databaseName": "auth",
				"owner":        "auth_app",
				"instance":     "auth",
				"extensions":   []any{"uuid-ossp", "pgcrypto"},
			},
		},
	})
	req := &fnv1.RunFunctionRequest{Observed: &fnv1.State{Composite: &fnv1.Resource{Resource: xr}}}

	f := &Function{log: logging.NewNopLogger()}
	rsp, err := f.RunFunction(context.Background(), req)
	if err != nil {
		t.Fatalf("RunFunction returned error: %v", err)
	}
	res := rsp.GetDesired().GetResources()
	for _, ext := range []string{"extension-uuid-ossp", "extension-pgcrypto"} {
		if _, ok := res[ext]; !ok {
			t.Errorf("expected a desired %q; got %v", ext, keysOfResources(res))
		}
	}
	if got := forProvider(t, res["extension-pgcrypto"])["extension"].GetStringValue(); got != "pgcrypto" {
		t.Errorf("extension forProvider.extension = %q, want pgcrypto", got)
	}
}

// TestRunFunction_RequiresParameters asserts a claim missing required
// parameters produces a fatal result and composes nothing.
func TestRunFunction_RequiresParameters(t *testing.T) {
	xr := mustStruct(t, map[string]any{
		"apiVersion": "platform.saas.example/v1alpha1",
		"kind":       "XAppDatabase",
		"spec":       map[string]any{"parameters": map[string]any{"databaseName": "x"}},
	})
	req := &fnv1.RunFunctionRequest{Observed: &fnv1.State{Composite: &fnv1.Resource{Resource: xr}}}

	f := &Function{log: logging.NewNopLogger()}
	rsp, err := f.RunFunction(context.Background(), req)
	if err != nil {
		t.Fatalf("RunFunction returned error: %v", err)
	}
	if _, ok := rsp.GetDesired().GetResources()["role"]; ok {
		t.Error("did not expect any composed resources when required parameters are missing")
	}
	if len(rsp.GetResults()) == 0 {
		t.Error("expected a fatal result for the missing parameters")
	}
}

func providerConfigName(res *fnv1.Resource) string {
	return res.GetResource().GetFields()["spec"].GetStructValue().
		GetFields()["providerConfigRef"].GetStructValue().
		GetFields()["name"].GetStringValue()
}

func keysOfResources(m map[string]*fnv1.Resource) []string {
	out := make([]string, 0, len(m))
	for k := range m {
		out = append(out, k)
	}
	return out
}
