
# ─── __INST__ ───────────────────────────────────────────────────────────────
---
apiVersion: external-secrets.io/v1beta1
kind: ExternalSecret
metadata:
  name: rds-__INST__-admin
  namespace: crossplane-system
  annotations:
    argocd.argoproj.io/sync-wave: "0"
spec:
  refreshInterval: 1h
  secretStoreRef:
    name: aws-secrets-manager
    kind: ClusterSecretStore
  target:
    name: rds-__INST__-admin
    creationPolicy: Owner
    template:
      type: Opaque
      data:
        data: |
          postgresql://{{ .username }}:{{ .password }}@{{ .endpoint }}/{{ .db_name }}?sslmode=require
        username: "{{ .username }}"
        password: "{{ .password }}"
        endpoint: "{{ .endpoint }}"
        db_name: "{{ .db_name }}"
  data:
    - { secretKey: username, remoteRef: { key: __SECRET__, property: username } }
    - { secretKey: password, remoteRef: { key: __SECRET__, property: password } }
    - { secretKey: endpoint, remoteRef: { key: __SECRET__, property: endpoint } }
    - { secretKey: db_name,  remoteRef: { key: __SECRET__, property: db_name  } }
---
apiVersion: postgresql.sql.crossplane.io/v1alpha1
kind: ProviderConfig
metadata:
  name: rds-__INST__
  annotations:
    argocd.argoproj.io/sync-wave: "1"
spec:
  credentials:
    source: PostgreSQLConnectionSecret
    connectionSecretRef:
      namespace: crossplane-system
      name: rds-__INST__-admin
  sslMode: require
