#!/bin/bash

# Exit immediately if any command fails
set -e

# Define variables
CLUSTER_NAME="dd-rosa"
NAMESPACE="federated-metrics"
S3_BUCKET="my-thanos-bucket"
ROLE_NAME="${CLUSTER_NAME}-thanos-s3"
SA="aws-prometheus-proxy"
TRUST_POLICY_FILE="TrustPolicy.json"
POLICY_NAME="${CLUSTER_NAME}-thanos"
POLICY_FILE="s3Policy.json"
SCRATCH_DIR="./"

# Get OIDC provider and AWS account ID
echo "Retrieving OIDC provider and AWS account ID..."

OIDC_PROVIDER=$(oc get authentication.config.openshift.io cluster -o json | jq -r .spec.serviceAccountIssuer | sed -e "s/^https:\/\///")
if [[ -z "$OIDC_PROVIDER" ]]; then
    echo "Error: Failed to retrieve OIDC provider. Exiting..."
    exit 1
fi

AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
if [[ -z "$AWS_ACCOUNT_ID" ]]; then
    echo "Error: Failed to retrieve AWS account ID. Exiting..."
    exit 1
fi

# Create s3Policy.json file
echo "Creating s3Policy.json..."
cat <<EOF > "${SCRATCH_DIR}/$POLICY_FILE"
{
    "Version": "2012-10-17",
    "Statement": [
        {
            "Effect": "Allow",
            "Action": [
                "s3:ListBucket",
                "s3:GetObject",
                "s3:DeleteObject",
                "s3:PutObject",
                "s3:PutObjectAcl"
            ],
            "Resource": [
                "arn:aws:s3:::$S3_BUCKET/*",
                "arn:aws:s3:::$S3_BUCKET"
            ]
        }
    ]
}
EOF

if [[ $? -ne 0 ]]; then
    echo "Error: Failed to create s3Policy.json. Exiting..."
    exit 1
fi

# Create TrustPolicy.json file
echo "Creating TrustPolicy.json..."
cat <<EOF > "${SCRATCH_DIR}/$TRUST_POLICY_FILE"
{
    "Version": "2012-10-17",
    "Statement": [
        {
            "Effect": "Allow",
            "Principal": {
                "Federated": "arn:aws:iam::${AWS_ACCOUNT_ID}:oidc-provider/${OIDC_PROVIDER}"
            },
            "Action": "sts:AssumeRoleWithWebIdentity",
            "Condition": {
                "StringEquals": {
                    "${OIDC_PROVIDER}:sub": [
                        "system:serviceaccount:${NAMESPACE}:${SA}"
                    ]
                }
            }
        }
    ]
}
EOF

if [[ $? -ne 0 ]]; then
    echo "Error: Failed to create TrustPolicy.json. Exiting..."
    exit 1
fi

echo "s3Policy.json and TrustPolicy.json created successfully."
echo ""

# Create S3 Policy
echo "Creating S3 policy from file: $POLICY_FILE"
S3_POLICY=$(aws iam create-policy --policy-name "$POLICY_NAME" --policy-document file://"$POLICY_FILE" --query "Policy.Arn" --output text)

# Check if policy creation was successful
if [[ -z "$S3_POLICY" ]]; then
    echo "Error: Failed to create S3 policy. Please check the policy file and try again."
    exit 1
fi

echo "ARN of S3 Policy is: $S3_POLICY"
echo ""

# Create Trust Policy for service account
echo "Creating Trust Policy for service account $SA with STS..."
S3_ROLE=$(aws iam create-role --role-name "$ROLE_NAME" --assume-role-policy-document file://"$TRUST_POLICY_FILE" --query "Role.Arn" --output text)

# Check if role creation was successful
if [[ -z "$S3_ROLE" ]]; then
    echo "Error: Failed to create IAM role. Please check the TrustPolicy file and try again."
    exit 1
fi

echo ""
echo "ARN of $SA Service Account Trust Policy is: $S3_ROLE"
echo ""

# Attach role to policy
echo "Attaching role $S3_ROLE to policy $S3_POLICY..."
aws iam attach-role-policy --role-name "$ROLE_NAME" --policy-arn "$S3_POLICY"

# Check if the policy was attached successfully
if [[ $? -ne 0 ]]; then
    echo "Error: Failed to attach policy to role. Exiting..."
    exit 1
fi

echo "Policy successfully attached to role."
echo ""

# Creating OpenShift project
echo "Creating OpenShift project..."
oc new-project "$NAMESPACE"

# Check if project creation was successful
if [[ $? -ne 0 ]]; then
    echo "Error: Failed to create OpenShift project. Exiting..."
    exit 1
fi

echo "Project created successfully."
echo ""

# Install Grafana Operator
echo "Installing Grafana Operator..."
helm upgrade --install grafana-operator install-grafana -n "$NAMESPACE"

# Pause to allow installation to complete
sleep 60

echo "Grafana Operator installed successfully."
echo ""

# Install Thanos Store Gateway
echo "Installing Thanos Gateway..."
helm upgrade rosa-thanos-s3 --install rosa-thanos-s3 --set "aws.roleArn=$S3_ROLE" --set "rosa.clusterName=$CLUSTER_NAME" -n "$NAMESPACE"

# Pause to allow installation to complete
sleep 60

echo "Thanos Gateway installed successfully."
echo ""

# Retrieve Grafana route
GRAFANA_ROUTE=$(oc get route grafana-route -o jsonpath='{"https://"}{.spec.host}{"\n"}')

# Check if Grafana route retrieval was successful
if [[ -z "$GRAFANA_ROUTE" ]]; then
    echo "Error: Failed to retrieve Grafana route. Please verify the route exists."
    exit 1
fi

echo "Grafana URL: $GRAFANA_ROUTE"
