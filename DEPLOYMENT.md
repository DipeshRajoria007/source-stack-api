# AWS Deployment Guide

This guide will help you deploy the SourceStack API to AWS using ECS Fargate, which is cost-effective and scalable.

## Architecture Overview

```
Internet
   ↓
Application Load Balancer (ALB)
   ↓
ECS Fargate Service (FastAPI)
   ↓
ElastiCache Redis (for Celery)
```

## Prerequisites

- AWS Account with $200 credit
- AWS CLI installed and configured (`aws configure`)
- Docker installed locally
- Basic understanding of AWS services

## Estimated Monthly Costs (with $200 credit)

- **ECS Fargate**: ~$15-30/month (0.5 vCPU, 1GB RAM, minimal traffic)
- **ElastiCache Redis**: ~$15-20/month (cache.t3.micro)
- **Application Load Balancer**: ~$16/month
- **ECR**: ~$0.50/month (storage)
- **Data Transfer**: ~$5-10/month (depending on usage)
- **Total**: ~$50-80/month (well within $200 credit)

## Step-by-Step Deployment

### 1. Build and Push Docker Image to ECR

#### 1.1 Create ECR Repository

```bash
aws ecr create-repository --repository-name source-stack-api --region us-east-1
```

Note the repository URI (e.g., `123456789012.dkr.ecr.us-east-1.amazonaws.com/source-stack-api`)

#### 1.2 Authenticate Docker to ECR

```bash
aws ecr get-login-password --region us-east-1 | docker login --username AWS --password-stdin 123456789012.dkr.ecr.us-east-1.amazonaws.com
```

Replace `123456789012` with your AWS account ID.

#### 1.3 Build and Push Image

```bash
# Build the image
docker build -t sourcestack-api .

# Tag for ECR
docker tag sourcestack-api:latest 123456789012.dkr.ecr.us-east-1.amazonaws.com/source-stack-api:latest

# Push to ECR
docker push 123456789012.dkr.ecr.us-east-1.amazonaws.com/source-stack-api:latest
```

### 2. Create ElastiCache Redis Cluster

#### 2.1 Create Redis Subnet Group

```bash
aws elasticache create-cache-subnet-group \
  --cache-subnet-group-name sourcestack-redis-subnet \
  --cache-subnet-group-description "Subnet group for SourceStack Redis" \
  --subnet-ids subnet-12345 subnet-67890 \
  --region us-east-1
```

**Note**: You'll need to create VPC and subnets first if you don't have them. See AWS VPC documentation.

#### 2.2 Create Security Group for Redis

```bash
# Create security group
aws ec2 create-security-group \
  --group-name sourcestack-redis-sg \
  --description "Security group for SourceStack Redis" \
  --vpc-id vpc-12345678 \
  --region us-east-1

# Allow inbound from ECS security group (update with your ECS SG ID)
aws ec2 authorize-security-group-ingress \
  --group-id sg-redis-12345 \
  --protocol tcp \
  --port 6379 \
  --source-group sg-ecs-12345 \
  --region us-east-1
```

#### 2.3 Create ElastiCache Redis Cluster

```bash
aws elasticache create-cache-cluster \
  --cache-cluster-id sourcestack-redis \
  --cache-node-type cache.t3.micro \
  --engine redis \
  --num-cache-nodes 1 \
  --cache-subnet-group-name sourcestack-redis-subnet \
  --security-group-ids sg-redis-12345 \
  --region us-east-1
```

Wait for cluster to be available (5-10 minutes), then get the endpoint:

```bash
aws elasticache describe-cache-clusters \
  --cache-cluster-id sourcestack-redis \
  --show-cache-node-info \
  --region us-east-1
```

Note the `Endpoint.Address` (e.g., `sourcestack-redis.xxxxx.cache.amazonaws.com`)

### 3. Create ECS Cluster and Task Definition

#### 3.1 Create ECS Cluster

```bash
aws ecs create-cluster --cluster-name sourcestack-cluster --region us-east-1
```

#### 3.2 Register Task Definition

Use the provided `ecs-task-definition.json` file:

```bash
aws ecs register-task-definition --cli-input-json file://ecs-task-definition.json --region us-east-1
```

**Important**: Update the following in `ecs-task-definition.json`:
- `image`: Your ECR repository URI
- `REDIS_URL`: Your ElastiCache Redis endpoint
- `API_KEY`: Your secure API key
- `CORS_ALLOW_ORIGINS`: Your frontend domain(s)

### 4. Create Application Load Balancer

#### 4.1 Create Target Group

```bash
aws elbv2 create-target-group \
  --name sourcestack-api-tg \
  --protocol HTTP \
  --port 8000 \
  --vpc-id vpc-12345678 \
  --health-check-path /health \
  --health-check-interval-seconds 30 \
  --health-check-timeout-seconds 5 \
  --healthy-threshold-count 2 \
  --unhealthy-threshold-count 3 \
  --region us-east-1
```

Note the Target Group ARN.

#### 4.2 Create Load Balancer

```bash
aws elbv2 create-load-balancer \
  --name sourcestack-api-alb \
  --subnets subnet-12345 subnet-67890 \
  --security-groups sg-alb-12345 \
  --region us-east-1
```

Note the Load Balancer ARN and DNS name.

#### 4.3 Create Listener

```bash
aws elbv2 create-listener \
  --load-balancer-arn arn:aws:elasticloadbalancing:us-east-1:123456789012:loadbalancer/app/sourcestack-api-alb/... \
  --protocol HTTP \
  --port 80 \
  --default-actions Type=forward,TargetGroupArn=arn:aws:elasticloadbalancing:us-east-1:123456789012:targetgroup/sourcestack-api-tg/... \
  --region us-east-1
```

### 5. Create ECS Service

```bash
aws ecs create-service \
  --cluster sourcestack-cluster \
  --service-name sourcestack-api-service \
  --task-definition sourcestack-api:1 \
  --desired-count 1 \
  --launch-type FARGATE \
  --network-configuration "awsvpcConfiguration={subnets=[subnet-12345,subnet-67890],securityGroups=[sg-ecs-12345],assignPublicIp=ENABLED}" \
  --load-balancers "targetGroupArn=arn:aws:elasticloadbalancing:us-east-1:123456789012:targetgroup/sourcestack-api-tg/...,containerName=sourcestack-api,containerPort=8000" \
  --region us-east-1
```

### 6. Verify Deployment

1. Check service status:
```bash
aws ecs describe-services --cluster sourcestack-cluster --services sourcestack-api-service --region us-east-1
```

2. Test health endpoint:
```bash
curl http://your-alb-dns-name.us-east-1.elb.amazonaws.com/health
```

3. Test API endpoint:
```bash
curl -X POST http://your-alb-dns-name.us-east-1.elb.amazonaws.com/parse \
  -H "X-API-Key: your-api-key" \
  -F "file=@test-resume.pdf"
```

## Running Celery Workers

For async job processing, you need to run Celery workers. You have two options:

### Option 1: Separate ECS Service (Recommended)

Create a separate task definition and service for Celery workers:

```bash
aws ecs register-task-definition --cli-input-json file://ecs-worker-task-definition.json --region us-east-1

aws ecs create-service \
  --cluster sourcestack-cluster \
  --service-name sourcestack-worker-service \
  --task-definition sourcestack-worker:1 \
  --desired-count 1 \
  --launch-type FARGATE \
  --network-configuration "awsvpcConfiguration={subnets=[subnet-12345,subnet-67890],securityGroups=[sg-ecs-12345],assignPublicIp=ENABLED}" \
  --region us-east-1
```

### Option 2: Same Container (Not Recommended for Production)

You can run both FastAPI and Celery in the same container, but this is not recommended for production scalability.

## Environment Variables

Create a `.env.production` file with:

```bash
API_KEY=your-secure-api-key-here
REDIS_URL=redis://sourcestack-redis.xxxxx.cache.amazonaws.com:6379/0
CORS_ALLOW_ORIGINS=https://your-frontend-domain.com
MAX_CONCURRENT_REQUESTS=10
SPREADSHEET_BATCH_SIZE=100
MAX_RETRIES=3
RETRY_DELAY=1.0
```

## Scaling

### Scale ECS Service

```bash
aws ecs update-service \
  --cluster sourcestack-cluster \
  --service sourcestack-api-service \
  --desired-count 2 \
  --region us-east-1
```

### Auto Scaling

Set up auto-scaling based on CPU/memory usage:

```bash
aws application-autoscaling register-scalable-target \
  --service-namespace ecs \
  --scalable-dimension ecs:service:DesiredCount \
  --resource-id service/sourcestack-cluster/sourcestack-api-service \
  --min-capacity 1 \
  --max-capacity 5 \
  --region us-east-1

aws application-autoscaling put-scaling-policy \
  --service-namespace ecs \
  --scalable-dimension ecs:service:DesiredCount \
  --resource-id service/sourcestack-cluster/sourcestack-api-service \
  --policy-name cpu-scaling-policy \
  --policy-type TargetTrackingScaling \
  --target-tracking-scaling-policy-configuration '{"TargetValue":70.0,"PredefinedMetricSpecification":{"PredefinedMetricType":"ECSServiceAverageCPUUtilization"}}' \
  --region us-east-1
```

## Monitoring

- **CloudWatch Logs**: View application logs
- **CloudWatch Metrics**: Monitor CPU, memory, request count
- **ECS Service Events**: Track deployment and service events

View logs:
```bash
aws logs tail /ecs/sourcestack-api --follow --region us-east-1
```

## Cost Optimization Tips

1. **Use Fargate Spot** for non-production workloads (up to 70% savings)
2. **Right-size containers**: Start with 0.5 vCPU, 1GB RAM, scale as needed
3. **Use ElastiCache t3.micro** for development/testing
4. **Set up CloudWatch alarms** to monitor costs
5. **Use Reserved Capacity** if running 24/7 (not needed with $200 credit initially)

## Troubleshooting

### Service won't start
- Check CloudWatch logs: `aws logs tail /ecs/sourcestack-api --follow`
- Verify task definition environment variables
- Check security group rules allow traffic

### Can't connect to Redis
- Verify security groups allow traffic on port 6379
- Check Redis endpoint is correct
- Ensure ECS tasks are in same VPC as Redis

### Health checks failing
- Verify `/health` endpoint works locally
- Check container port is 8000
- Verify target group health check path

## Next Steps

1. Set up HTTPS with ACM certificate
2. Configure custom domain with Route 53
3. Set up CI/CD pipeline (GitHub Actions, CodePipeline)
4. Enable CloudWatch alarms for monitoring
5. Set up backup/restore for Redis if needed

## Alternative: AWS Elastic Beanstalk (Easier, Less Control)

If you prefer a simpler deployment:

```bash
# Install EB CLI
pip install awsebcli

# Initialize EB
eb init -p docker sourcestack-api --region us-east-1

# Create environment
eb create sourcestack-api-env

# Deploy
eb deploy
```

However, Elastic Beanstalk doesn't handle Redis/Celery as easily, so ECS is recommended.

