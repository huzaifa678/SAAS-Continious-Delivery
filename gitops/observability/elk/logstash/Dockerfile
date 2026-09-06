# Logstash + AWS MSK IAM auth. The uber-jar must live on the Logstash classpath
# (logstash-core/lib/jars) so the kafka input's AWS_MSK_IAM SASL mechanism and
# IAMClientCallbackHandler resolve at runtime.
#
# Build & push to the platform registry, then set logstash.image/imageTag in
# values.yaml (LOGSTASH_MSK_IMAGE / LOGSTASH_MSK_TAG) from the gitops contract.
FROM docker.elastic.co/logstash/logstash:8.5.1

ARG MSK_IAM_AUTH_VERSION=2.2.0
ADD --chown=logstash:logstash \
    https://github.com/aws/aws-msk-iam-auth/releases/download/v${MSK_IAM_AUTH_VERSION}/aws-msk-iam-auth-${MSK_IAM_AUTH_VERSION}-all.jar \
    /usr/share/logstash/logstash-core/lib/jars/aws-msk-iam-auth.jar
