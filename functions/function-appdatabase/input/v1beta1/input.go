// Package v1beta1 contains the input type for the function-appdatabase
// composition function. The composition passes an Input in its pipeline step;
// everything here has a sane default so the composition can stay minimal.
//
// +kubebuilder:object:generate=true
// +groupName=appdatabase.fn.saas.example
// +versionName=v1beta1
package v1beta1

import (
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
)

// Input configures the appdatabase composition function.
//
// +kubebuilder:object:root=true
type Input struct {
	metav1.TypeMeta `json:",inline"`

	// +optional
	ProviderConfigFormat string `json:"providerConfigFormat,omitempty"`

	// +optional
	ConnectionSecretNamespace string `json:"connectionSecretNamespace,omitempty"`
}
