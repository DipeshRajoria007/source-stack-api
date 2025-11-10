# Quick Start: Deploy to AWS in 30 Minutes

This is a simplified guide to get you started quickly. For detailed information, see [DEPLOYMENT.md](./DEPLOYMENT.md).

## Prerequisites Checklist

- [ ] AWS Account with $200 credit
- [ ] AWS CLI installed (`aws --version`)
- [ ] AWS CLI configured (`aws configure`)
- [ ] Docker installed and running
- [ ] Basic understanding of AWS (or follow along)

## Quick Deployment Steps

### 1. Set Up AWS CLI (5 minutes)

```bash
# Install AWS CLI (if not installed)
# macOS:
brew install awscli

# Linux:
curl "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o "awscliv2.zip"
unzip awscliv2.zip
sudo ./aws/install

# Configure AWS CLI
aws configure
# Enter your AWS Access Key ID
# Enter your AWS Secret Access Key
# Default region: us-east-1 (or your preferred region)
# Default output format: json
```

### 2. Create VPC and Networking (10 minutes)

**Option A: Use Default VPC (Easiest for testing)**

```bash
# Get your default VPC ID
VPC_ID=$(aws ec2 describe-vpcs --filters "Name=isDefault,Values=true" --query "Vpcs[0].VpcId" --output text)
echo "VPC ID: $VPC_ID"

# Get default subnets
SUBNET_IDS=$(aws ec2 describe-subnets --filters "Name=vpc-id,Values=$VPC_ID" --query "Subnets[*].SubnetId" --output text | tr '\t' ' ')
echo "Subnets: $SUBNET_IDS"
```

**Option B: Create New VPC (Recommended for production)**

See AWS VPC documentation or use AWS Console to create:

- VPC with CIDR 10.0.0.0/16
- 2 public subnets in different AZs
- Internet Gateway
- Route tables

### 3. Create IAM Roles (5 minutes)

Create `iam-setup.sh`:

```bash
#!/bin/bash
# Create IAM roles for ECS  

# Create task execution role
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

# Attach policy
aws iam attach-role-policy \
  --role-name ecsTaskExecutionRole \
  --policy-arn arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy

# Create CloudWatch log group
aws logs create-log-group --log-group-name /ecs/sourcestack-api || true
aws logs create-log-group --log-group-name /ecs/sourcestack-worker || true
```

Run it:

```bash
chmod +x iam-setup.sh
./iam-setup.sh
```

### 4. Build and Push Docker Image (5 minutes)

```bash
# Make deploy script executable
chmod +x deploy.sh

# Run deployment script
./deploy.sh
```

This will:

- Create ECR repository
- Build Docker image
- Push to ECR

### 5. Create ElastiCache Redis (10 minutes)

```bash
# Get your VPC ID (from step 2)
VPC_ID="vpc-xxxxx"  # Replace with your VPC ID

# Create subnet group (use your subnet IDs from step 2)
aws elasticache create-cache-subnet-group \
  --cache-subnet-group-name sourcestack-redis-subnet \
  --cache-subnet-group-description "Subnet group for SourceStack Redis" \
  --subnet-ids subnet-xxxxx subnet-yyyyy

# Create security group
SG_ID=$(aws ec2 create-security-group \
  --group-name sourcestack-redis-sg \
  --description "Security group for SourceStack Redis" \
  --vpc-id $VPC_ID \
  --query 'GroupId' --output text)

echo "Security Group ID: $SG_ID"

# Create Redis cluster
aws elasticache create-cache-cluster \
  --cache-cluster-id sourcestack-redis \
  --cache-node-type cache.t3.micro \
  --engine redis \
  --num-cache-nodes 1 \
  --cache-subnet-group-name sourcestack-redis-subnet \
  --security-group-ids $SG_ID

# Wait for cluster (this takes 5-10 minutes)
echo "Waiting for Redis cluster to be available..."
aws elasticache wait cache-cluster-available --cache-cluster-id sourcestack-redis

# Get Redis endpoint
REDIS_ENDPOINT=$(aws elasticache describe-cache-clusters \
  --cache-cluster-id sourcestack-redis \
  --show-cache-node-info \
  --query 'CacheClusters[0].CacheNodes[0].Endpoint.Address' \
  --output text)

echo "Redis Endpoint: $REDIS_ENDPOINT"
```

### 6. Update Task Definition (2 minutes)

Edit `ecs-task-definition.json`:

1. Replace `YOUR_ACCOUNT_ID` with your AWS account ID (from `aws sts get-caller-identity`)
2. Replace the `image` URL with your ECR URI (from deploy.sh output)
3. Update `REDIS_URL` with the endpoint from step 5
4. Set a secure `API_KEY`
5. Update `CORS_ALLOW_ORIGINS` with your frontend domain (or keep `*` for testing)

### 7. Register Task Definition and Create Service (5 minutes)

```bash
# Register task definition
aws ecs register-task-definition --cli-input-json file://ecs-task-definition.json

# Create ECS cluster
aws ecs create-cluster --cluster-name sourcestack-cluster || true

# Create security group for ECS tasks
ECS_SG_ID=$(aws ec2 create-security-group \
  --group-name sourcestack-ecs-sg \
  --description "Security group for SourceStack ECS tasks" \
  --vpc-id $VPC_ID \
  --query 'GroupId' --output text)

# Allow inbound HTTP from anywhere (or restrict to ALB later)
aws ec2 authorize-security-group-ingress \
  --group-id $ECS_SG_ID \
  --protocol tcp \
  --port 8000 \
  --cidr 0.0.0.0/0

# Allow ECS to connect to Redis
aws ec2 authorize-security-group-ingress \
  --group-id $SG_ID \
  --protocol tcp \
  --port 6379 \
  --source-group $ECS_SG_ID

# Create service (without load balancer first)
aws ecs create-service \
  --cluster sourcestack-cluster \
  --service-name sourcestack-api-service \
  --task-definition sourcestack-api:1 \
  --desired-count 1 \
  --launch-type FARGATE \
  --network-configuration "awsvpcConfiguration={subnets=[subnet-xxxxx,subnet-yyyyy],securityGroups=[$ECS_SG_ID],assignPublicIp=ENABLED}"
```

### 8. Get Public IP and Test (3 minutes)

```bash
# Get task public IP
TASK_ARN=$(aws ecs list-tasks --cluster sourcestack-cluster --service-name sourcestack-api-service --query 'taskArns[0]' --output text)
TASK_IP=$(aws ecs describe-tasks --cluster sourcestack-cluster --tasks $TASK_ARN --query 'tasks[0].attachments[0].details[?name==`networkInterfaceId`].value' --output text | xargs -I {} aws ec2 describe-network-interfaces --network-interface-ids {} --query 'NetworkInterfaces[0].Association.PublicIp' --output text)

echo "API is running at: http://$TASK_IP:8000"

# Test health endpoint
curl http://$TASK_IP:8000/health

# Test API endpoint
curl -X POST http://$TASK_IP:8000/parse \
  -H "X-API-Key: your-api-key-here" \
  -F "file=@test-resume.pdf"
```

## Next Steps

1. **Add Load Balancer**: See DEPLOYMENT.md for ALB setup
2. **Set up Celery Worker**: Register worker task definition and create service
3. **Configure HTTPS**: Add ACM certificate and HTTPS listener
4. **Set up Domain**: Use Route 53 to point domain to load balancer
5. **Monitor**: Set up CloudWatch alarms and dashboards

## Troubleshooting

### Service won't start

```bash
# Check service events
aws ecs describe-services --cluster sourcestack-cluster --services sourcestack-api-service

# Check logs
aws logs tail /ecs/sourcestack-api --follow
```

### Can't connect to Redis

- Verify security groups allow traffic
- Check Redis endpoint is correct
- Ensure tasks are in same VPC

### Health checks failing

- Check container logs
- Verify `/health` endpoint works
- Check security group allows inbound traffic

## Cost Estimate

With this setup:

- **ECS Fargate**: ~$15/month (0.5 vCPU, 1GB RAM, minimal usage)
- **ElastiCache**: ~$15/month (cache.t3.micro)
- **Data Transfer**: ~$5/month
- **Total**: ~$35/month (well within $200 credit)

## Need Help?

- Check [DEPLOYMENT.md](./DEPLOYMENT.md) for detailed instructions
- AWS ECS Documentation: https://docs.aws.amazon.com/ecs/
- AWS ElastiCache Documentation: https://docs.aws.amazon.com/elasticache/

http://sourcestack-redis-nwq1lm.serverless.aps1.cache.amazonaws.com:6379/