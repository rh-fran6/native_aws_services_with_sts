#!/bin/bash

# Exit immediately if any command fails
set -e

# Define variables
export CLUSTER_NAME="dd-rosa"
export NAMESPACE="dontest"
export S3_BUCKET="sts-s3-bucket-17042024-demo"
export ROLE_NAME="${CLUSTER_NAME}-demo-s3"
export SA="install-with-sts"
export SA_NOT="install-without-sts"
export TRUST_POLICY_FILE="TrustPolicy.json"
export POLICY_NAME="${CLUSTER_NAME}-demo-s3"
export POLICY_FILE="s3Policy.json"
export SCRATCH_DIR="./"
export APP_NAME="aws-cli-app"
export CONFIG_MAP="${NAMESPACE}-configmap"

## Create s3 Bucket
# echo Creating S3 buckets...
# aws s3 mb s3://$S3_BUCKET

# Creating OpenShift project
echo "Creating OpenShift project..."
oc new-project "$NAMESPACE"


# Create service account to test files upload
echo "Creating service accounts to test file uploads..."

for i in $SA $SA_NOT; do
  oc create sa $i -n $NAMESPACE
done

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

echo ""
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

echo ""
aws iam attach-role-policy --role-name "$ROLE_NAME" --policy-arn "$S3_POLICY" >> /dev/null

aws iam attach-role-policy --role-name dd-rosa-demo-s3 --policy-arn arn:aws:iam::069165561352:policy/dd-rosa-demo-s3

# Check if the policy was attached successfully
if [[ $? -ne 0 ]]; then
    echo "Error: Failed to attach policy to role. Exiting..."
    exit 1
fi

echo "Policy successfully attached to role."
echo ""


## Annotating Service Accounts 
echo "Annotating Service Account "
for i in $SA ; do 
  echo oc -n $NAMESPACE  annotate serviceaccount $i eks.amazonaws.com/role-arn=$S3_ROLE
  oc -n $NAMESPACE  annotate serviceaccount $i eks.amazonaws.com/role-arn=$S3_ROLE
done

sleep 15

# Check if project creation was successful
if [[ $? -ne 0 ]]; then
    echo "Error: Failed to create OpenShift project. Exiting..."
    exit 1
fi

echo "Project created successfully."
echo ""

# Create config map to test files upload
echo "Creating config maps to test file uploads..."

oc create configmap $CONFIG_MAP --from-file=data=configmap.txt -n $NAMESPACE

# Create AWS CLI Test deployment
echo "Creating a Test Deployments for sts and non-sts credentials"

for i in $SA $SA_NOT; do cat <<EOF | oc apply -f -
apiVersion: apps/v1
kind: Deployment
metadata:
  name: $i
  namespace: $NAMESPACE
  labels:
    app: $i
spec:
  replicas: 1
  selector:
    matchLabels:
      app: $i
  template:
    metadata:
      labels:
        app: $i
    spec:
      containers:
        - image: amazon/aws-cli:latest
          name: awscli-$i
          command:
            - /bin/sh
            - "-c"
            - while true; do sleep 10; done
          env:
            - name: HOME
              value: /tmp          
          resources:
            requests:
              memory: "64Mi"
              cpu: "250m"
            limits:
              memory: "128Mi"
              cpu: "500m"
          volumeMounts:
            - name: $CONFIG_MAP
              mountPath: /tmp/testdata      
      serviceAccount: $i
      volumes:
        - name: $CONFIG_MAP
          configMap:
            name: $CONFIG_MAP 
EOF
done

echo ""

# Wait to allow installation to complete
#!/bin/bash

# Define variables
DEPLOYMENTS=($SA $SA_NOT)  # List of deployments

# Function to check readiness of a deployment
check_deployment_readiness() {
  local deployment_name=$1
  while true; do
    # Get the number of ready pods and the total number of pods in the deployment
    READY_PODS=$(kubectl get deployment "$deployment_name" -n "$NAMESPACE" -o jsonpath='{.status.readyReplicas}')
    TOTAL_PODS=$(kubectl get deployment "$deployment_name" -n "$NAMESPACE" -o jsonpath='{.status.replicas}')

    # Check if all pods are ready
    if [[ "$READY_PODS" == "$TOTAL_PODS" && "$TOTAL_PODS" != "0" ]]; 
        then
        echo "All pods in deployment '$deployment_name' are ready."
        echo "Completed"
        break
    fi

    # Wait for a short time before checking again
    sleep 5
  done
}

# Check readiness for each deployment in the list
for deployment in "${DEPLOYMENTS[@]}"; do
  echo "Checking readiness for deployment: $deployment"
  check_deployment_readiness "$deployment"
done

echo "Test application created successfully."
echo ""

# 

## Testing file upload ##
echo ""

echo "Checking pod status..."

oc get pods -n $NAMESPACE

sleep 45

#!/bin/bash

# Ensure necessary variables are set
if [[ -z "$NAMESPACE" || -z "$S3_BUCKET" || -z "$SA" || -z "$SA_NOT" ]]; then
    echo "Error: Required variables (NAMESPACE, S3_BUCKET, SA, SA_NOT) are not set."
    exit 1
fi

# Function to execute AWS CLI commands in a pod
execute_aws_cli() {
    local pod_name=$1

    echo "Running AWS CLI commands in pod: $pod_name"
    echo ""
    # List the contents of the S3 bucket
    if ! oc exec "$pod_name" -- aws s3 ls "s3://$S3_BUCKET"; then
        echo "Error: Failed to list contents of S3 bucket in pod: $pod_name"
    fi
    echo ""
    # Copy file from pod to S3 bucket
    if ! oc exec "$pod_name" -- aws s3 cp /tmp/testdata/data "s3://$S3_BUCKET/sts-test-data"; then
        echo "Error: Failed to copy file to S3 bucket in pod: $pod_name"
    fi
    echo ""
    # List the contents of the S3 bucket again
    if ! oc exec "$pod_name" -- aws s3 ls "s3://$S3_BUCKET"; then
        echo "Error: Failed to list contents of S3 bucket in pod: $pod_name"
    fi

    echo "AWS CLI commands completed successfully in pod: $pod_name"
    echo ""
}

# Function to execute AWS CLI commands for a given app label
execute_commands_for_app() {
    local app_label=$1

    # Get the names of the pods with the specified app label
    pod_names=$(oc get pods -n "$NAMESPACE" --selector="app=$app_label" -o jsonpath='{.items[*].metadata.name}')
    echo ""
    if [[ -z "$pod_names" ]]; then
        echo "No pods found with label app=$app_label in namespace $NAMESPACE."
        return
    fi
    echo ""
    # Iterate through the pod names and execute AWS CLI commands
    for pod_name in $pod_names; do
        execute_aws_cli "$pod_name"
    done
    echo ""
}

# Execute commands for both SA and SA_NOT apps
execute_commands_for_app "$SA"
execute_commands_for_app "$SA_NOT"


echo ""

echo "Completed"

