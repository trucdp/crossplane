# Source: https://gist.github.com/a156975ae372bf15284e15c489aab4aa

##########################################################################
# Crossplane                                                             #
# Using Kubernetes API and GitOps to manage Infrastructure as Code (IaC) #
# https://youtu.be/n8KjVmuHm7A                                           #
##########################################################################

# Referenced videos:
# - Argo CD - Applying GitOps Principles To Manage Production Environment In Kubernetes: https://youtu.be/vpWQeoaiRM4

#########
# Setup #
#########

# The examples are using Kode Kloud (GCP)!
# https://kodekloud.com/topic/crossplane-aws/


# Create an account in https://cloud.upbound.io/register or https://crossplane.io/docs/v1.0/getting-started/install-configure.html#start-with-a-self-hosted-crossplane

curl -sL https://raw.githubusercontent.com/crossplane/crossplane/release-1.0/install.sh | sh
# Create a namespace argocd
kubectl create namespace argocd
# To install Non-HA v2.4.11 ArgoCD within argocd namespace run the below command:
kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/v2.4.11/manifests/install.yaml
kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml
# You can check the argocd-cm config map data entries using
kubectl -n argocd get cm argocd-cm
# Edit ArgoCD Server service and convert it from type ClusterIP to NodePort
kubectl edit svc argocd-server -n argocd
# Change type: ClusterIP to type: Nodeport and under -https add nodePort 32766 name:https and nodePort 32766
kubectl patch svc argocd-server -n argocd -p '{"spec": {"type": "NodePort"}}'
# Fetch the ArgoCD initial Admin Password using kubectl -n argocd get secrets argocd-initial-admin-secret -o json | jq .data.password -r | tr -d '\n' | base64 -d command.
kubectl -n argocd get secrets argocd-initial-admin-secret -o json | jq .data.password -r | tr -d '\n'  | base64 -d
# Read the instructions from the output to finish the installation
# Install ArgoCD CLI v2.4.11.
curl -sSL -o /usr/local/bin/argocd https://github.com/argoproj/argo-cd/releases/download/v2.4.11/argocd-linux-amd64
chmod +x /usr/local/bin/argocd
# Open https://github.com/trucdp/crossplane.git
# HashiCorp Vault with ArgoCD Vault Plugin
vault secrets enable -path=crds kv-v2
vault kv put crds/mysql MYSQL-PASSWORD=12345678
# Install AVP
curl -Lo argocd-vault-plugin https://github.com/argoproj-labs/argocd-vault-plugin/releases/download/{version}/argocd-vault-plugin_{version}_{linux|darwin}_{amd64|arm64|s390x}
chmod +x argocd-vault-plugin
mv argocd-vault-plugin /usr/local/bin

# Fork it!

# Replace `[...]` with the GitHub organization or the username
export GH_ORG=[...]

git clone https://github.com/$GH_ORG/crossplane-demo.git

cd crossplane-demo

# Replace `[...]` with the base host accessible through NGINX Ingress
export BASE_HOST=[...] # e.g., `$(minikube ip).nip.io`

#########################
# Setup: Deploy Argo CD #
#########################

cat argo-cd/base/ingress.yaml \
    | sed -e "s@acme.com@argo-cd.$BASE_HOST@g" \
    | tee argo-cd/overlays/production/ingress.yaml

cat production/argo-cd.yaml \
    | sed -e "s@vfarcic@$GH_ORG@g" \
    | tee production/argo-cd.yaml

cat apps.yaml \
    | sed -e "s@vfarcic@$GH_ORG@g" \
    | tee apps.yaml

git add .

git commit -m "Initial commit"

git push

kustomize build \
    argo-cd/overlays/production \
    | kubectl apply --filename -

kubectl --namespace argocd \
    rollout status \
    deployment argocd-server

export PASS=$(kubectl \
    --namespace argocd \
    get secret argocd-initial-admin-secret \
    --output jsonpath="{.data.password}" \
    | base64 --decode)

argocd login \
    --insecure \
    --username admin \
    --password $PASS \
    --grpc-web \
    argo-cd.$BASE_HOST

argocd account update-password \
    --current-password $PASS \
    --new-password admin123

kubectl apply --filename project.yaml

kubectl apply --filename apps.yaml

############################
# Setup: Deploy Crossplane #
############################

helm repo add crossplane-stable \
    https://charts.crossplane.io/stable

helm repo update

helm upgrade --install \
    crossplane crossplane-stable/crossplane \
    --namespace crossplane-system \
    --create-namespace \
    --wait

##############
# Setup: GCP #
##############

export PROJECT_ID=devops-toolkit-$(date +%Y%m%d%H%M%S)

gcloud projects create $PROJECT_ID

echo https://console.cloud.google.com/marketplace/product/google/container.googleapis.com?project=$PROJECT_ID

# Open the URL and *ENABLE* the API

export SA_NAME=devops-toolkit

export SA="${SA_NAME}@${PROJECT_ID}.iam.gserviceaccount.com"

gcloud iam service-accounts \
    create $SA_NAME \
    --project $PROJECT_ID

export ROLE=roles/admin

gcloud projects add-iam-policy-binding \
    --role $ROLE $PROJECT_ID \
    --member serviceAccount:$SA

gcloud iam service-accounts keys \
    create creds.json \
    --project $PROJECT_ID \
    --iam-account $SA

kubectl --namespace crossplane-system \
    create secret generic gcp-creds \
    --from-file key=./creds.json

####################
# Create resources #
####################

kubectl crossplane install provider \
    crossplane/provider-gcp:v0.15.0

kubectl get providers

# Repeat the previous command until `HEALTHY` column is set to `True`

echo "apiVersion: gcp.crossplane.io/v1beta1
kind: ProviderConfig
metadata:
  name: default
spec:
  projectID: $PROJECT_ID
  credentials:
    source: Secret
    secretRef:
      namespace: crossplane-system
      name: gcp-creds
      key: key" \
    | kubectl apply --filename -

cat gke.yaml

kubectl apply --filename gke.yaml

kubectl get gkeclusters

kubectl get nodepools

################################
# Doing what shouldn't be done #
################################

export KUBECONFIG=$PWD/kubeconfig.yaml

gcloud container clusters \
    get-credentials devops-toolkit \
    --region us-east1 \
    --project $PROJECT_ID

kubectl get nodes

# Open the Web console and add the missing zones

kubectl get nodes

####################
# Update resources #
####################

cat gke-region.yaml

cp gke-region.yaml production/gke.yaml

git add .

git commit -m "GKE"

git push

kubectl get nodes

#####################
# Destroy resources #
#####################

rm production/gke.yaml

git add .

git commit -m "GKE"

git push

gcloud projects delete $PROJECT_ID

minikube delete

##############
# Setup: AWS #
##############
