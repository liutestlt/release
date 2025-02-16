#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

export PATH=$PATH:/tmp/bin
mkdir -p /tmp/bin

echo "$(date -u --rfc-3339=seconds) - Installing tools..."

# install jq
# TODO move to image
curl -sL https://github.com/stedolan/jq/releases/download/jq-1.6/jq-linux64 > /tmp/bin/jq
chmod ug+x /tmp/bin/jq

# install newest oc
curl https://mirror.openshift.com/pub/openshift-v4/clients/oc/latest/linux/oc.tar.gz | tar xvzf - -C /tmp/bin/ oc
chmod ug+x /tmp/bin/oc


# set the parameters we'll need as env vars
AZURE_AUTH_LOCATION="${CLUSTER_PROFILE_DIR}/osServicePrincipal.json"
AZURE_AUTH_CLIENT_ID="$(cat ${AZURE_AUTH_LOCATION} | jq -r .clientId)"
AZURE_AUTH_CLIENT_SECRET="$(cat ${AZURE_AUTH_LOCATION} | jq -r .clientSecret)"
AZURE_AUTH_TENANT_ID="$(cat ${AZURE_AUTH_LOCATION} | jq -r .tenantId)"

CLUSTER_NAME="$(oc get -o jsonpath='{.status.infrastructureName}' infrastructure cluster)"
echo "Cluster name: $CLUSTER_NAME"
CLUSTER_VERSION="$(/tmp/bin/oc adm release info -o json | jq -r .metadata.version)"
echo "Cluster version: $CLUSTER_VERSION"
RESOURCE_GROUP="$(oc get -o jsonpath='{.status.platformStatus.azure.resourceGroupName}' infrastructure cluster)"
echo "Resource group: $RESOURCE_GROUP"

echo "$(date -u --rfc-3339=seconds) - Logging in to Azure..."
az login --service-principal -u "${AZURE_AUTH_CLIENT_ID}" -p "${AZURE_AUTH_CLIENT_SECRET}" --tenant "${AZURE_AUTH_TENANT_ID}"

echo "$(date -u --rfc-3339=seconds) - Listing load balancer resources"
LB_RESOURCES="$(az resource list --resource-type Microsoft.Network/loadBalancers --resource-group $RESOURCE_GROUP | jq -r '.[].id')"

OUTPUT_DIR="${ARTIFACT_DIR}/azure-monitor-metrics/"
mkdir -p "$OUTPUT_DIR"

for i in $LB_RESOURCES; do
    echo "$i"
    LB_NAME="$(basename $i)" # Grabs the last token of the resource id, which is it's friendly name.
    echo "$LB_NAME"
    metrics=( SnatConnectionCount AllocatedSnatPorts UsedSnatPorts PacketCount ByteCount )
    for m in "${metrics[@]}";
    do
        echo "$(date -u --rfc-3339=seconds) - Gathering metric $m for load balancer $i"
        az monitor metrics list --resource $i --offset 3h --metrics $m > $OUTPUT_DIR/lb-$LB_NAME-$m.json
    done
    # One-off additional filter for failed connections:
    az monitor metrics list --resource $i --offset 3h --metrics SnatConnectionCount --filter "ConnectionState eq 'Failed'" > $OUTPUT_DIR/lb-$LB_NAME-SnatConnectionCount-ConnectionFailed.json
done

