# Logstash + AWS MSK IAM auth.
#
# The kafka input's AWS_MSK_IAM SASL mechanism uses
# software.amazon.msk.auth.iam.IAMClientCallbackHandler, which implements
# kafka-clients' org.apache.kafka.common.security.auth.AuthenticateCallbackHandler.
#
# In Logstash 8.x, kafka-clients is loaded by the logstash-integration-kafka
# plugin's OWN classloader (vendor/jar-dependencies, via require_jar). A jar placed
# in logstash-core/lib/jars lands on the parent/boot classpath, which CANNOT see the
# plugin's kafka-clients — so IAMClientCallbackHandler fails to link at pipeline
# start with "NoClassDefFoundError: .../AuthenticateCallbackHandler". (This worked on
# the old 8.5.1 image but regressed on the 8.19 bump / integration-kafka 11.x.)
#
# Fix: install the IAM jar INTO the kafka plugin's jar-dependencies tree and register
# it in the plugin's jar manifest, so it is loaded by the same classloader as
# kafka-clients and the handler resolves.
#
# Build & push to the platform registry, then set logstash.image/imageTag in
# values.yaml (LOGSTASH_MSK_IMAGE / LOGSTASH_MSK_TAG) from the gitops contract.
# 8.5.1 was ~3 years old and failed the image scan on OS + bundled-jar CVEs; 8.19.x
# clears the bulk of them (stays output-compatible with the 8.5.1 ES/Kibana charts).
FROM docker.elastic.co/logstash/logstash:8.19.19

ARG MSK_IAM_AUTH_VERSION=2.2.0
ADD --chown=logstash:logstash \
    https://github.com/aws/aws-msk-iam-auth/releases/download/v${MSK_IAM_AUTH_VERSION}/aws-msk-iam-auth-${MSK_IAM_AUTH_VERSION}-all.jar \
    /tmp/aws-msk-iam-auth.jar

RUN set -eux; \
    plugin_dir="$(find /usr/share/logstash/vendor/bundle -maxdepth 7 -type d -name 'logstash-integration-kafka-*-java' -print -quit)"; \
    test -n "$plugin_dir"; \
    jars_rb="$(find "$plugin_dir/lib" -name '*_jars.rb' -print -quit)"; \
    test -n "$jars_rb"; \
    dest="$plugin_dir/vendor/jar-dependencies/software/amazon/msk/aws-msk-iam-auth/${MSK_IAM_AUTH_VERSION}"; \
    mkdir -p "$dest"; \
    cp /tmp/aws-msk-iam-auth.jar "$dest/aws-msk-iam-auth-${MSK_IAM_AUTH_VERSION}.jar"; \
    printf "\nrequire_jar('software.amazon.msk', 'aws-msk-iam-auth', '%s')\n" "${MSK_IAM_AUTH_VERSION}" >> "$jars_rb"; \
    rm -f /tmp/aws-msk-iam-auth.jar
