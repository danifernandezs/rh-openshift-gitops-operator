#!/bin/bash

set -o errexit  # exit when a command fails
set -o nounset  # exit when use undeclared variables
set -o pipefail # return the exit code of the last command that threw a non-zero

# Checking the requirements

# Check if yq is installed
if ! command -v yq > /dev/null; then
    echo "Error: yq is not installed. Please install yq through https://github.com/mikefarah/yq/#install and try again."
    exit 1
fi

# Check if oc is installed
if ! command -v oc > /dev/null; then
    echo "Error: oc is not installed. Please install oc through https://docs.openshift.com/container-platform/4.8/cli_reference/openshift_cli/getting-started-cli.html and try again."
    exit 1
fi

# Check connectivity with the OpenShift cluster
if ! oc get pods > /dev/null 2>&1; then
    echo "Error: unable to connect to the OpenShift cluster. Please check your network connection or configuration and try again."
    exit 1
fi

# Connectivity with the OpenShift cluster is successful, so continue with the script
echo "Successfully connected to the OpenShift cluster, continuing ..."
echo ""

# Obtaining the desired subscription name
export SUBS_NAME=$(yq '.metadata.name' gitops-operator/subscription.yaml)
# echo "$SUBS_NAME"

# Obtaining the namespace where the resource it's applied
export SUBS_NAMESPACE=$(yq '.metadata.namespace' gitops-operator/subscription.yaml)
# echo "$SUBS_NAMESPACE"

# Applying the subscription resource
oc apply -f gitops-operator/subscription.yaml
sleep 5

# Obtaining the referenced InstallPlan
export REF_INSTALLPLAN=$(oc get subscription.operators.coreos.com $SUBS_NAME -n $SUBS_NAMESPACE -o 'jsonpath={..status.installPlanRef.name}')
# echo "$REF_INSTALLPLAN"

# Checking if the installplan is approved or not
if [[ $(oc get installplan.operators.coreos.com $REF_INSTALLPLAN -n $SUBS_NAMESPACE -o 'jsonpath={..spec.approved}') == "false" ]]
then
  sleep 1
  echo "The InstallPlan is not approved."
  echo "---   ---   ---   ---   ---   ---"

  oc patch installplan $REF_INSTALLPLAN \
      -n $SUBS_NAMESPACE \
      --type merge \
      --patch '{"spec":{"approved":true}}'

  oc patch installplan $REF_INSTALLPLAN \
      -n $SUBS_NAMESPACE \
      --type merge \
      --patch '{"metadata":{"labels":{"patched-timestamp":"'$(date +"%Y-%m-%d_%H-%M")'"}}}'
else
  echo "The InstallPlan has been approved."
  echo ""
  echo "Time to check if the operator is at Ready status"

fi

# Checking the complete status at the install plan
if [[ $(oc get installplan.operators.coreos.com $REF_INSTALLPLAN -n $SUBS_NAMESPACE -o 'jsonpath={..status.phase}') != "Complete" ]]
then
  echo "The InstallPlan is not at completed status."
  echo "---   ---   ---   ---   ---   ---"
  sleep 1
  while true; do
    if [ $(oc get installplan.operators.coreos.com $REF_INSTALLPLAN -n $SUBS_NAMESPACE -o 'jsonpath={..status.phase}') == "Complete" ]; then
      # If the install plan is complete, print a message and exit the loop
      echo "Install plan completed"
      break
    else
      # If the install plan is not complete, print a message and sleep for 30 seconds
      echo "Install plan not completed, sleeping for 5 seconds"
      echo "..."
      sleep 5
    fi
  done
else
  echo "The InstallPlan is already at a completed status"
  echo ""
  echo ""
fi

while [[ $( oc get pods -l app.kubernetes.io/name=openshift-gitops-server -n openshift-gitops -o 'jsonpath={..status.conditions[?(@.type=="Ready")].status}') != "True" ]]; do
  sleep 1
  echo "We are waiting to a Ready Default ArgoCD instance. No action required, just wait."
  echo "..."
  sleep 5
done

# Delete the default ArgoCD Instance and AppProjects
echo ""
echo "Delete the default ArgoCD Instance and the default AppProject resource"
sleep 1
oc delete argocd.argoproj.io --all -n openshift-gitops
oc delete appproject.argoproj.io --all -n openshift-gitops


# Deploy the desired ArgoCD Instance and AppProjects
echo ""
echo "Deploy the desired ArgoCD Instance"
sleep 1
oc create -f gitops-operator/argocd-instance.yaml -n openshift-gitops

while [[ $( oc get pods -l app.kubernetes.io/name=argocd-gitops-instance-server -n openshift-gitops -o 'jsonpath={..status.conditions[?(@.type=="Ready")].status}') != "True" ]]; do
  sleep 1
  echo "We are waiting to a Ready Default ArgoCD instance. No action required, just wait."
  echo "..."
  sleep 5
done

echo ""
echo "Deploy the desired AppProject resources"
sleep 1
oc delete appproject.argoproj.io --all -n openshift-gitops
oc create -f appprojects/ -n openshift-gitops

# Deploy the initial ArgoCD Applications, as seed of GitOps
# App of Apps of ApplicationSets
echo ""
echo "Deploy the initial ArgoCD Applications as seed of GitOps"
sleep 1
oc create -f argo-applications/ -n openshift-gitops

echo "---------------------------------------------------"
echo "             Your ArgoCD WebUI URL"
echo "---------------------------------------------------"

oc get route -l  app.kubernetes.io/name=argocd-gitops-instance-server -n openshift-gitops -o 'jsonpath={..spec.host}'
echo ""
echo ""

