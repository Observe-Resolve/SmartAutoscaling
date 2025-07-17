#!/usr/bin/env bash

################################################################################
### Script deploying the Observ-K8s environment
### Parameters:
### Clustern name: name of your k8s cluster
### dttoken: Dynatrace api token with ingest metrics and otlp ingest scope
### dturl : url of your DT tenant wihtout any / at the end for example: https://dedede.live.dynatrace.com
################################################################################


### Pre-flight checks for dependencies
if ! command -v jq >/dev/null 2>&1; then
    echo "Please install jq before continuing"
    exit 1
fi

if ! command -v git >/dev/null 2>&1; then
    echo "Please install git before continuing"
    exit 1
fi


if ! command -v helm >/dev/null 2>&1; then
    echo "Please install helm before continuing"
    exit 1
fi

if ! command -v kubectl >/dev/null 2>&1; then
    echo "Please install kubectl before continuing"
    exit 1
fi
echo "parsing arguments"
while [ $# -gt 0 ]; do
  case "$1" in
   --dtoperatortoken)
          DTOPERATORTOKEN="$2"
         shift 2
          ;;
       --dtingesttoken)
          DTTOKEN="$2"
         shift 2
          ;;
       --dturl)
          DTURL="$2"
         shift 2
          ;;
       --clustername)
         CLUSTERNAME="$2"
         shift 2
         ;;
        --environment)
        ENVIRONMENT="$2"
        shift 2
        ;;
       --oauthclientid)
         OAUTH_CLIENT_ID="$2"
         shift 2
         ;;
        --oauthclientsecret)
          OAUTH_CLIENT_SECRET="$2"
          shift 2
          ;;
      --oauthclienturn)
          OAUTH_CLIENT_URN="$2"
          shift 2
          ;;

  *)
    echo "Warning: skipping unsupported option: $1"
    shift
    ;;
  esac
done
echo "Checking arguments"
 if [ -z "$CLUSTERNAME" ]; then
   echo "Error: clustername not set!"
   exit 1
 fi
  if [ -z "$ENVIRONMENT" ]; then
    ENVIRONMENT="live"

  fi
  if [ -z "$OAUTH_CLIENT_SECRET" ]; then
    echo "Error: client secret not set!"
      exit 1

  fi


      if [ -z "$OAUTH_CLIENT_URN" ]; then
        echo "Error: client urn not set!"
          exit 1

      fi
    if [ -z "$OAUTH_CLIENT_ID" ]; then
      echo "Error: client id not set!"
        exit 1

    fi
 if [ -z "$DTURL" ]; then
   echo "Error: Dt url not set!"
   exit 1
 fi

 if [ -z "$DTTOKEN" ]; then
   echo "Error: Data ingest api-token not set!"
   exit 1
 fi

 if [ -z "$DTOPERATORTOKEN" ]; then
   echo "Error: DT operator token not set!"
   exit 1
 fi

DT_TENANT_ID=$(echo $DTURL| cut -d'/' -f3 | grep -o -E '([^.]+)' | head -1)

if [ "$ENVIRONMENT" == "live" ]; then
  export DYNATRACE_LIVE_URL="$DT_TENANT_ID.live.dynatrace.com"
  export DYNATRACE_APPS_URL="$DT_TENANT_ID.apps.dynatrace.com"
  export DYNATRACE_SSO_URL="sso.dynatrace.com/sso/oauth2/token"
else
  export DYNATRACE_LIVE_URL="$DT_TENANT_ID.$ENVIRONMENT.dynatracelabs.com"
  export DYNATRACE_APPS_URL="$DT_TENANT_ID.$ENVIRONMENT.apps.dynatracelabs.com"
  export DYNATRACE_SSO_URL="sso-$ENVIRONMENT.dynatracelabs.com/sso/oauth2/token"
fi

#### Deploy the cert-manager
echo "Deploying Cert Manager ( for OpenTelemetry Operator)"
kubectl apply -f https://github.com/cert-manager/cert-manager/releases/download/v1.10.0/cert-manager.yaml
# Wait for pod webhook started
kubectl wait pod -l app.kubernetes.io/component=webhook -n cert-manager --for=condition=Ready --timeout=2m
# Deploy the opentelemetry operator
sleep 10
echo "Deploying the OpenTelemetry Operator"
kubectl apply -f https://github.com/open-telemetry/opentelemetry-operator/releases/latest/download/opentelemetry-operator.yaml



#### Deploy the Dynatrace Operator
kubectl create namespace dynatrace
kubectl apply -f https://github.com/Dynatrace/dynatrace-operator/releases/download/v1.6.0/kubernetes.yaml
kubectl apply -f https://github.com/Dynatrace/dynatrace-operator/releases/download/v1.6.0/kubernetes-csi.yaml
kubectl -n dynatrace wait pod --for=condition=ready --selector=app.kubernetes.io/name=dynatrace-operator,app.kubernetes.io/component=webhook --timeout=300s
kubectl -n dynatrace create secret generic dynakube --from-literal="apiToken=$DTOPERATORTOKEN" --from-literal="dataIngestToken=$DTTOKEN"
sed -i '' "s,TENANTURL_TOREPLACE,$DTURL," dynatrace/dynakube.yaml
sed -i '' "s,CLUSTER_NAME_TO_REPLACE,$CLUSTERNAME,"  dynatrace/dynakube.yaml
sed -i '', "s,TENANTID_TOREPLACE,$DT_TENANT_ID," dynatrace/edge-connect.yaml
sed -i '', "s,SSO_URL_TO_REPLACE,$DYNATRACE_SSO_URL," dynatrace/edge-connect.yaml
sed -i '', "s,API_URL_TO_REPLACE,$DYNATRACE_APPS_URL," dynatrace/edge-connect.yaml
sed -i '', "s,URN_TO_REPLACE,$OAUTH_CLIENT_URN," dynatrace/edge-connect.yaml

kubectl --namespace dynatrace \
  create secret generic "edgeconnect-oauth" \
  --from-literal=oauth-client-id="$OAUTH_CLIENT_ID" \
  --from-literal=oauth-client-secret="$OAUTH_CLIENT_SECRET"

#Deploy collector
kubectl create secret generic dynatrace  --from-literal=dynatrace_oltp_url="$DTURL" --from-literal=clustername="$CLUSTERNAME"  --from-literal=clusterid=$CLUSTERID  --from-literal=dt_api_token="$DTTOKEN"


#deploy demo application
kubectl apply -f dynatrace/dynakube.yaml -n dynatrace
kubectl apply -f dynatrace/edge-connect.yaml -n dynatrace
kubectl create ns otel-demo
kubectl label namespace  otel-demo oneagent=false

kubectl apply -f opentelemetry/deploy_2_02.yaml -n otel-demo


