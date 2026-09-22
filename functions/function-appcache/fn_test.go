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

func metaLabel(res *fnv1.Resource, key string) string {
	return res.GetResource().GetFields()["metadata"].GetStructValue().
		GetFields()["labels"].GetStructValue().GetFields()[key].GetStringValue()
}

func run(t *testing.T, params map[string]any) map[string]*fnv1.Resource {
	t.Helper()
	xr := mustStruct(t, map[string]any{
		"apiVersion": "platform.saas.example/v1alpha1",
		"kind":       "XAppCache",
		"metadata":   map[string]any{"uid": "uid-1"},
		"spec":       map[string]any{"parameters": params},
	})
	req := &fnv1.RunFunctionRequest{Observed: &fnv1.State{Composite: &fnv1.Resource{Resource: xr}}}
	f := &Function{log: logging.NewNopLogger()}
	rsp, err := f.RunFunction(context.Background(), req)
	if err != nil {
		t.Fatalf("RunFunction returned error: %v", err)
	}
	return rsp.GetDesired().GetResources()
}

// TestShared asserts a shared claim composes a single prefix-scoped ACL user,
// labelled for the shared user group.
func TestShared(t *testing.T) {
	res := run(t, map[string]any{
		"serviceName": "billing",
		"mode":        "shared",
		"keyPrefix":   "billing",
	})

	u, ok := res["acl-user"]
	if !ok {
		t.Fatalf("expected a desired acl-user; got %v", keysOfResources(res))
	}
	if got := forProvider(t, u)["accessString"].GetStringValue(); got != "on ~billing:* resetchannels +@all -@dangerous" {
		t.Errorf("accessString = %q", got)
	}
	if got := metaLabel(u, "platform.saas.example/redis-tenant-group"); got != "saas-redis" {
		t.Errorf("tenant-group label = %q, want saas-redis", got)
	}
	if got := providerConfigName(u); got != "aws-elasticache" {
		t.Errorf("providerConfigRef.name = %q, want aws-elasticache", got)
	}
	if _, ok := res["replication-group"]; ok {
		t.Error("shared mode must not compose a replication-group")
	}
}

// TestDedicated asserts a dedicated claim composes its own cluster + RBAC group,
// honouring the shard count.
func TestDedicated(t *testing.T) {
	res := run(t, map[string]any{
		"serviceName": "agent",
		"mode":        "dedicated",
		"numShards":   2,
		"numReplicas": 1,
	})

	for _, name := range []string{"default-user", "app-user", "user-group", "replication-group"} {
		if _, ok := res[name]; !ok {
			t.Fatalf("expected a desired %q; got %v", name, keysOfResources(res))
		}
	}
	rg := forProvider(t, res["replication-group"])
	if got := rg["numNodeGroups"].GetNumberValue(); got != 2 {
		t.Errorf("numNodeGroups = %v, want 2", got)
	}
	if got := rg["nodeType"].GetStringValue(); got != "cache.t4g.medium" {
		t.Errorf("nodeType = %q, want the default cache.t4g.medium", got)
	}
	if got := rg["transitEncryptionEnabled"].GetBoolValue(); !got {
		t.Error("transitEncryptionEnabled must be true")
	}
}

// TestRequiresServiceName asserts a claim missing serviceName composes nothing
// and returns a fatal result.
func TestRequiresServiceName(t *testing.T) {
	res := run(t, map[string]any{"mode": "shared"})
	if len(res) != 0 {
		t.Errorf("expected no composed resources, got %v", keysOfResources(res))
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
