#!/bin/bash

# Exit immediately if any command fails
set -e

# Define variables
export CLUSTER_NAME="dd-rosa"
export NAMESPACE="dontest"
export ROLE_NAME="${CLUSTER_NAME}-demo-s3"
export POLICY_NAME="${CLUSTER_NAME}-demo-s3"
export CONFIG_MAP="${NAMESPACE}-configmap"
export SA="install-with-sts"
export SA_NOT="install-without-sts"
export S3_BUCKET="sts-s3-bucket-17042024-demo"
export TRUST_POLICY_FILE="TrustPolicy.json"
export POLICY_FILE="s3Policy.json"

## Deleting S3 buckets
# aws s3 rm s3://$S3_BUCKET

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

# Deleting service account to test files upload
echo "Deleting service accounts to test file uploads..."

for i in $SA $SA_NOT; do
  oc delete serviceaccount $i -n $NAMESPACE
done


# Delete Deployments $SA and $SA_NOT
echo "Deleting $SA and $SA_NOT Deployments..."
for i in $SA $SA_NOT; do 
  oc delete deployment $i 
done


# Delete configmap
echo "Deleting $CONFIG_MAP..."
oc delete configmap $CONFIG_MAP 

# Delete OpenShift project
echo "Deleting OpenShift project..."
oc delete project "$NAMESPACE"

rm -rf $TRUST_POLICY_FILE
rm -rf $POLICY_FILE

# Completion message
echo "Completed"
