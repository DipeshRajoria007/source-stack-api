#!/bin/bash

# IAM Setup Script for SourceStack API ECS Deployment
# This script creates the necessary IAM roles and policies for ECS tasks

set -e

echo "Setting up IAM roles for ECS..."

# Get AWS account ID
AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
if [ -z "$AWS_ACCOUNT_ID" ]; then
    echo "Error: Could not get AWS account ID. Is AWS CLI configured?"
    exit 1
fi

echo "AWS Account ID: $AWS_ACCOUNT_ID"

# Create task execution role (if it doesn't exist)
if aws iam get-role --role-name ecsTaskExecutionRole &> /dev/null; then
    echo "Role 'ecsTaskExecutionRole' already exists"
else
    echo "Creating ecsTaskExecutionRole..."
    aws iam create-role \
        --role-name ecsTaskExecutionRole \
        --assume-role-policy-document '{
            "Version": "2012-10-17",
            "Statement": [{
                "Effect": "Allow",
                "Principal": {"Service": "ecs-tasks.amazonaws.com"},
                "Action": "sts:AssumeRole"
            }]
        }'
    
    # Attach the managed policy
    aws iam attach-role-policy \
        --role-name ecsTaskExecutionRole \
        --policy-arn arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy
    
    echo "✓ Created ecsTaskExecutionRole"
fi

# Create task role (for application-level permissions)
if aws iam get-role --role-name ecsTaskRole &> /dev/null; then
    echo "Role 'ecsTaskRole' already exists"
else
    echo "Creating ecsTaskRole..."
    aws iam create-role \
        --role-name ecsTaskRole \
        --assume-role-policy-document '{
            "Version": "2012-10-17",
            "Statement": [{
                "Effect": "Allow",
                "Principal": {"Service": "ecs-tasks.amazonaws.com"},
                "Action": "sts:AssumeRole"
            }]
        }'
    
    echo "✓ Created ecsTaskRole (no policies attached - add as needed)"
fi

# Create CloudWatch log groups
echo "Creating CloudWatch log groups..."
aws logs create-log-group --log-group-name /ecs/sourcestack-api 2>/dev/null || echo "Log group /ecs/sourcestack-api already exists"
aws logs create-log-group --log-group-name /ecs/sourcestack-worker 2>/dev/null || echo "Log group /ecs/sourcestack-worker already exists"

echo ""
echo "✓ IAM setup complete!"
echo ""
echo "Task Execution Role ARN: arn:aws:iam::${AWS_ACCOUNT_ID}:role/ecsTaskExecutionRole"
echo "Task Role ARN: arn:aws:iam::${AWS_ACCOUNT_ID}:role/ecsTaskRole"
echo ""
echo "Update your ecs-task-definition.json with these ARNs."

