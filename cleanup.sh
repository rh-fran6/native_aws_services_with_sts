#!/bin/bash

# Exit immediately if any command fails
set -e

# Define variables
CLUSTER_NAME="dd-rosa"
NAMESPACE="federated-metrics"
ROLE_NAME="${CLUSTER_NAME}-thanos-s3"
POLICY_NAME="${CLUSTER_NAME}-thanos"

# Function to print error message and exit
function handle_error {
    echo "An error occurred. Exiting..."
    exit 1
}

# Trap errors and handle them using the handle_error function
trap handle_error ERR

# Grab policy ARN
echo "Retrieving IAM policy ARN..."
POLICY_ARN=$(aws iam list-policies --query "Policies[?PolicyName=='$POLICY_NAME'].Arn" --output text)
if [[ -z "$POLICY_ARN" ]]; then
    echo "Policy $POLICY_NAME not found. Exiting..."
    exit 1
fi

# Detach policy from role
echo "Detaching IAM policy from role..."
aws iam detach-role-policy --role-name "$ROLE_NAME" --policy-arn "$POLICY_ARN"

# Delete IAM role
echo "Deleting IAM role..."
aws iam delete-role --role-name "$ROLE_NAME"

# Delete IAM policy
echo "Deleting IAM policy..."
aws iam delete-policy --policy-arn "$POLICY_ARN"



# Delete OpenShift project
echo "Deleting OpenShift project..."
oc delete project "$NAMESPACE"

# Uninstall Thanos Gateway
echo "Uninstalling Thanos Gateway..."
helm uninstall rosa-thanos-s3 -n "$NAMESPACE"

# Uninstall Grafana Operator
echo "Uninstalling Grafana Operator..."
helm uninstall grafana-operator

rm -rf s3Policy.json
rm -rf TrustPolicy.json

# Completion message
echo "Completed"
