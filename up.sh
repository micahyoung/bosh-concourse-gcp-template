#!/bin/bash
set -o errexit
set -o nounset
set -o pipefail

if ! [ -d state/ ]; then
  exit "No State, exiting"
  exit 1
fi

source ./state/env.sh
GCP_PROJECT_ID=${GCP_PROJECT_ID:?"!"}
GCP_PROJECT_DOMAIN=${GCP_PROJECT_DOMAIN:?"!"}
GCP_SERVICE_ACCOUNT_NAME=${GCP_SERVICE_ACCOUNT_NAME:?"!"}
GCP_REGION=${GCP_REGION:?"!"}
GCP_ZONE=${GCP_ZONE:?"!"}
CONCOURSE_USERNAME=${CONCOURSE_USERNAME:?"!"}
CONCOURSE_PASSWORD=${CONCOURSE_PASSWORD:?"!"}
CONCOURSE_TARGET=${CONCOURSE_TARGET:?"!"}
CONCOURSE_DB_NAME=${CONCOURSE_DB_NAME:?"!"}
CONCOURSE_DB_ROLE=${CONCOURSE_DB_ROLE:?"!"}
CONCOURSE_DB_PASSWORD=${CONCOURSE_DB_PASSWORD:?"!"}
DOMAIN=${DOMAIN:?"!"}
CONCOURSE_BOSH_ENV=${CONCOURSE_BOSH_ENV:?"!"}
CONCOURSE_DEPLOYMENT_NAME=${CONCOURSE_DEPLOYMENT_NAME:?"!"}
set -x


mkdir -p bin
PATH=$PATH:$(pwd)/bin

if ! [ -f bin/bosh ]; then
  curl -L "https://s3.amazonaws.com/bosh-cli-artifacts/bosh-cli-2.0.1-darwin-amd64" > bin/bosh
  chmod +x bin/bosh
fi

if ! [ -f bin/terraform ]; then
  curl -L "https://releases.hashicorp.com/terraform/0.9.4/terraform_0.9.4_darwin_amd64.zip" | funzip > bin/terraform
  chmod +x bin/terraform
fi

bbl_cmd="bbl --state-dir state/"
if ! [ -f bin/bbl ]; then
  curl -L "https://github.com/cloudfoundry/bosh-bootloader/releases/download/v3.0.4/bbl-v3.0.4_osx" > bin/bbl
  chmod +x bin/bbl
fi

if ! gcloud --version; then
  brew cask install google-cloud-sdk
fi

if ! gcloud auth list | grep ACTIVE >/dev/null; then
  gcloud auth login
fi

if ! gcloud config get-value project | grep $GCP_PROJECT_ID >/dev/null; then
  gcloud config set project $GCP_PROJECT_ID
fi

if ! gcloud iam service-accounts list | grep $GCP_SERVICE_ACCOUNT_NAME >/dev/null; then
  gcloud iam service-accounts create $GCP_SERVICE_ACCOUNT_NAME
fi

if ! [ -f state/$GCP_SERVICE_ACCOUNT_NAME.key.json ]; then
  gcloud iam service-accounts keys create --iam-account=$GCP_SERVICE_ACCOUNT_NAME@$GCP_PROJECT_DOMAIN state/$GCP_SERVICE_ACCOUNT_NAME.key.json
fi

if ! gcloud projects get-iam-policy $GCP_PROJECT_ID | grep $GCP_SERVICE_ACCOUNT_NAME >/dev/null; then
  gcloud projects add-iam-policy-binding $GCP_PROJECT_ID --member=serviceAccount:$GCP_SERVICE_ACCOUNT_NAME@$GCP_PROJECT_DOMAIN --role='roles/editor'
fi

if ! [ -f state/bbl-state.json ]; then
  $bbl_cmd \
    up \
    --gcp-service-account-key state/$GCP_SERVICE_ACCOUNT_NAME.key.json \
    --gcp-project-id $GCP_PROJECT_ID \
    --gcp-region $GCP_REGION \
    --gcp-zone $GCP_ZONE \
    --iaas gcp \
  ;
fi

if ! [ -f state/bosh.pem ]; then
  $bbl_cmd ssh-key > state/bosh.pem
  chmod 600 state/bosh.pem
fi

if ! [ -f state/$DOMAIN.key ]; then
  echo generate cert and key manually using bosh ssh and certbot on the web instance
  exit 1
fi

if ! $bbl_cmd lbs; then
  $bbl_cmd \
    create-lbs \
    --type concourse \
    --cert state/$DOMAIN.crt \
    --key state/$DOMAIN.key
fi

DIRECTOR_ADDRESS=$($bbl_cmd director-address)
if ! bosh env --environment $DIRECTOR_ADDRESS; then
  bosh alias-env $CONCOURSE_BOSH_ENV \
    --environment $DIRECTOR_ADDRESS \
    --ca-cert <($bbl_cmd director-ca-cert) \
    --client $($bbl_cmd director-username) \
    --client-secret $($bbl_cmd director-password) \
  ;

  bosh log-in \
    --environment $CONCOURSE_BOSH_ENV \
    --ca-cert <($bbl_cmd director-ca-cert) \
    --client $($bbl_cmd director-username) \
    --client-secret $($bbl_cmd director-password) \
  ;
fi

if ! bosh stemcells -e $CONCOURSE_BOSH_ENV | grep -q bosh-google-kvm-ubuntu-trusty-go_agent; then
  bosh upload-stemcell -e $CONCOURSE_BOSH_ENV https://s3.amazonaws.com/bosh-core-stemcells/google/bosh-stemcell-3363.20-google-kvm-ubuntu-trusty-go_agent.tgz
fi

if ! [ -f state/concourse-creds.yml ]; then
  # from https://github.com/cloudfoundry/bosh-bootloader/blob/master/docs/concourse_aws.md
  cat > state/concourse-creds.yml <<EOF
concourse_deployment_name: $CONCOURSE_DEPLOYMENT_NAME
concourse_external_url: https://$DOMAIN
concourse_basic_auth_username: $CONCOURSE_USERNAME
concourse_basic_auth_password: $CONCOURSE_PASSWORD
concourse_atc_db_name: $CONCOURSE_DB_NAME
concourse_atc_db_role: $CONCOURSE_DB_ROLE
concourse_atc_db_password: $CONCOURSE_DB_PASSWORD
concourse_tls_cert: !!binary $(base64 state/$DOMAIN.crt)
concourse_tls_key: !!binary $(base64 state/$DOMAIN.key)
concourse_vm_type: n1-standard-1
concourse_worker_vm_extensions: 50GB_ephemeral_disk
concourse_web_vm_extensions: lb
concourse_db_disk_type: 5GB
EOF
fi

if ! bosh deployments -e $CONCOURSE_BOSH_ENV | grep -q $CONCOURSE_DEPLOYMENT_NAME; then
  bosh deploy \
    --non-interactive \
    --environment $CONCOURSE_BOSH_ENV \
    --deployment $CONCOURSE_DEPLOYMENT_NAME \
    --vars-store state/concourse-creds.yml \
    concourse-deployment.yml \
  ;
fi

if ! [ -f bin/fly ]; then
  curl -L "https://$DOMAIN/api/v1/cli?arch=amd64&platform=darwin" > bin/fly
  chmod +x bin/fly
fi

# if we can set the target with default password, update the password
if fly login \
  --target $CONCOURSE_TARGET \
  --concourse-url "https://$DOMAIN" \
  --username admin \
  --password password 2>/dev/null; then
  echo y | fly set-team \
    --target $CONCOURSE_TARGET \
    --team-name main \
    --basic-auth-username=$CONCOURSE_USERNAME \
    --basic-auth-password=$CONCOURSE_PASSWORD \
  ;
fi
