#!/bin/bash

echo "=========================================="
echo "SourceStack API Configuration Diagnostic"
echo "=========================================="
echo ""

# 1. Check IAM Roles
echo "=== 1. IAM Roles ==="
echo ""
echo "Task Execution Role (ecsTaskExecutionRole):"
aws iam get-role --role-name ecsTaskExecutionRole --query 'Role.{RoleName:RoleName,Arn:Arn}' --output table 2>/dev/null || echo "✗ ecsTaskExecutionRole NOT FOUND"
echo ""

echo "ECS-TASK-Role:"
aws iam get-role --role-name ECS-TASK-Role --query 'Role.{RoleName:RoleName,Arn:Arn}' --output table 2>/dev/null || echo "✗ ECS-TASK-Role NOT FOUND"
echo ""

echo "Policies attached to ECS-TASK-Role:"
aws iam list-attached-role-policies --role-name ECS-TASK-Role --output table 2>/dev/null || echo "✗ Cannot list policies"
echo ""

# 2. Check ECS Cluster and Service
echo "=== 2. ECS Cluster ==="
aws ecs describe-clusters --clusters sourcestack-cluster --region ap-south-1 --query 'clusters[0].{Name:clusterName,Status:status,ActiveServices:activeServicesCount}' --output table 2>/dev/null || echo "✗ Cluster not found"
echo ""

echo "=== 3. ECS Service ==="
aws ecs describe-services --cluster sourcestack-cluster --services sourcestack-api-service --region ap-south-1 --query 'services[0].{ServiceName:serviceName,Status:status,DesiredCount:desiredCount,RunningCount:runningCount,TaskDefinition:taskDefinition}' --output table 2>/dev/null || echo "✗ Service not found"
echo ""

echo "=== Recent Service Events ==="
aws ecs describe-services --cluster sourcestack-cluster --services sourcestack-api-service --region ap-south-1 --query 'services[0].events[:5]' --output table 2>/dev/null || echo "✗ Cannot get events"
echo ""

# 3. Check Task Definition
echo "=== 4. Task Definition ==="
TASK_DEF=$(aws ecs describe-services --cluster sourcestack-cluster --services sourcestack-api-service --region ap-south-1 --query 'services[0].taskDefinition' --output text 2>/dev/null)

if [ ! -z "$TASK_DEF" ] && [ "$TASK_DEF" != "None" ]; then
    echo "Task Definition: $TASK_DEF"
    echo ""
    echo "Task Definition Details:"
    aws ecs describe-task-definition --task-definition $TASK_DEF --region ap-south-1 --query 'taskDefinition.{Family:family,ExecutionRoleArn:executionRoleArn,TaskRoleArn:taskRoleArn,NetworkMode:networkMode,CPU:cpu,Memory:memory}' --output table
    echo ""
    echo "Container Image:"
    aws ecs describe-task-definition --task-definition $TASK_DEF --region ap-south-1 --query 'taskDefinition.containerDefinitions[0].{Name:name,Image:image}' --output table
    echo ""
    echo "Environment Variables:"
    aws ecs describe-task-definition --task-definition $TASK_DEF --region ap-south-1 --query 'taskDefinition.containerDefinitions[0].environment' --output table
else
    echo "✗ Cannot get task definition"
fi
echo ""

# 4. Check Tasks
echo "=== 5. Current Tasks ==="
TASK_ARN=$(aws ecs list-tasks --cluster sourcestack-cluster --service-name sourcestack-api-service --region ap-south-1 --query 'taskArns[0]' --output text 2>/dev/null)

if [ ! -z "$TASK_ARN" ] && [ "$TASK_ARN" != "None" ]; then
    echo "Task ARN: $TASK_ARN"
    echo ""
    echo "Task Status:"
    aws ecs describe-tasks --cluster sourcestack-cluster --tasks $TASK_ARN --region ap-south-1 --query 'tasks[0].{LastStatus:lastStatus,DesiredStatus:desiredStatus,StoppedReason:stoppedReason,StoppedAt:stoppedAt}' --output table
    echo ""
    echo "Container Status:"
    aws ecs describe-tasks --cluster sourcestack-cluster --tasks $TASK_ARN --region ap-south-1 --query 'tasks[0].containers[0].{Name:name,LastStatus:lastStatus,Reason:reason,ExitCode:exitCode}' --output table
else
    echo "✗ No running tasks found"
fi
echo ""

# 5. Check Network Configuration
echo "=== 6. Network Configuration ==="
VPC_ID=$(aws ec2 describe-vpcs --filters "Name=tag:Name,Values=source-stack-vpc" --query 'Vpcs[0].VpcId' --output text --region ap-south-1 2>/dev/null)

if [ ! -z "$VPC_ID" ] && [ "$VPC_ID" != "None" ]; then
    echo "VPC ID: $VPC_ID"
    echo ""
    echo "Service Network Config:"
    aws ecs describe-services --cluster sourcestack-cluster --services sourcestack-api-service --region ap-south-1 --query 'services[0].networkConfiguration.awsvpcConfiguration.{Subnets:subnets,SecurityGroups:securityGroups,AssignPublicIp:assignPublicIp}' --output table 2>/dev/null || echo "✗ Cannot get network config"
else
    echo "✗ VPC not found"
fi
echo ""

# 6. Check Security Groups
if [ ! -z "$VPC_ID" ] && [ "$VPC_ID" != "None" ]; then
    echo "=== 7. Security Groups ==="
    aws ec2 describe-security-groups --filters "Name=vpc-id,Values=$VPC_ID" --query 'SecurityGroups[?contains(GroupName, `sourcestack`) || contains(GroupName, `source-stack`)].{GroupId:GroupId,GroupName:GroupName}' --output table --region ap-south-1
    echo ""
fi

# 7. Check CloudWatch Logs
echo "=== 8. CloudWatch Logs ==="
LOG_STREAM=$(aws logs describe-log-streams --log-group-name /ecs/sourcestack-api --order-by LastEventTime --descending --max-items 1 --region ap-south-1 --query 'logStreams[0].logStreamName' --output text 2>/dev/null)

if [ ! -z "$LOG_STREAM" ] && [ "$LOG_STREAM" != "None" ]; then
    echo "Latest log stream: $LOG_STREAM"
    echo ""
    echo "Last 20 Log Entries:"
    aws logs get-log-events --log-group-name /ecs/sourcestack-api --log-stream-name "$LOG_STREAM" --limit 20 --region ap-south-1 --query 'events[*].message' --output text 2>/dev/null | tail -20
else
    echo "✗ No log streams found"
fi
echo ""

# 8. Check ECR Repository
echo "=== 9. ECR Repository ==="
aws ecr describe-repositories --repository-names source-stack-api --region ap-south-1 --query 'repositories[0].{Name:repositoryName,URI:repositoryUri}' --output table 2>/dev/null || echo "✗ Repository not found"
echo ""

echo "ECR Images:"
aws ecr list-images --repository-name source-stack-api --region ap-south-1 --output table 2>/dev/null || echo "✗ Cannot list images"
echo ""

# 9. Check Redis
echo "=== 10. Redis Configuration ==="
aws elasticache describe-serverless-caches --serverless-cache-name sourcestack-redis --region ap-south-1 --query 'ServerlessCaches[0].{Name:ServerlessCacheName,Status:Status,Endpoint:Endpoint.Address}' --output table 2>/dev/null || echo "✗ Redis cluster not found (may be using different type)"
echo ""

echo "=========================================="
echo "Diagnostic Complete"
echo "=========================================="

