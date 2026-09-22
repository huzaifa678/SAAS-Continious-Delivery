// Package v1beta1 contains the input type for the function-appcache composition
// function. The composition passes an Input in its pipeline step; everything
// here has a sane default so the composition can stay minimal.
//
// +kubebuilder:object:generate=true
// +groupName=appcache.fn.saas.example
// +versionName=v1beta1
package v1beta1

import (
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
)

// Input configures the appcache composition function.
//
// +kubebuilder:object:root=true
type Input struct {
	metav1.TypeMeta `json:",inline"`

	// ProviderConfigName is the provider-aws ProviderConfig every composed
	// ElastiCache resource references. Defaults to "aws-elasticache".
	// +optional
	ProviderConfigName string `json:"providerConfigName,omitempty"`

	// DefaultUserGroupID is the shared cluster's RBAC user group a shared-mode
	// tenant joins when the claim does not set userGroupId. Defaults to
	// "saas-redis".
	// +optional
	DefaultUserGroupID string `json:"defaultUserGroupId,omitempty"`
}
