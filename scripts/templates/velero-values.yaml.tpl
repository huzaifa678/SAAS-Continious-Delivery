# Velero S3 BackupStorageLocation, from the observability gitops_contract
# (backup.bucket + region; bucket created by Terraform 40-observability).
# Nested under `velero:` — this is an umbrella chart over the velero subchart.
velero:
  configuration:
    backupStorageLocation:
      - name: default
        provider: aws
        bucket: __BUCKET__
        default: true
        config:
          region: __REGION__
