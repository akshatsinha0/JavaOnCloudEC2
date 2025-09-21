# JavaOnEC2 - v1 Deployment Runbook (PowerShell)

Run these commands one-by-one in VS Code Terminal (pwsh). Assumes AWS CLI v2 and Docker Desktop are installed.

1) Set AWS profile and region, verify identity

```powershell
$env:AWS_PROFILE="java-ec2"
$env:AWS_REGION = "us-east-1"
aws sts get-caller-identity --output json --region $env:AWS_REGION --profile $env:AWS_PROFILE
```

2) Compute artifact bucket name (account+region)

```powershell
$acct = (aws sts get-caller-identity --query Account --output text --region $env:AWS_REGION --profile $env:AWS_PROFILE).Trim()
$env:S3_BUCKET = ("java-ec2-artifacts-{0}-{1}" -f $acct, $env:AWS_REGION).ToLower()
$env:S3_BUCKET
```

3) Create/secure the S3 artifact bucket (idempotent)

```powershell
try {
  if ($env:AWS_REGION -eq "us-east-1") {
    aws s3api create-bucket --bucket $env:S3_BUCKET --region $env:AWS_REGION --profile $env:AWS_PROFILE | Out-Null
  } else {
    aws s3api create-bucket --bucket $env:S3_BUCKET --region $env:AWS_REGION --create-bucket-configuration LocationConstraint=$env:AWS_REGION --profile $env:AWS_PROFILE | Out-Null
  }
} catch { Write-Host "Bucket may already exist—continuing" }
aws s3api put-bucket-versioning --bucket $env:S3_BUCKET --versioning-configuration Status=Enabled --profile $env:AWS_PROFILE
aws s3api put-public-access-block --bucket $env:S3_BUCKET --public-access-block-configuration BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true --profile $env:AWS_PROFILE
aws s3api put-bucket-encryption --bucket $env:S3_BUCKET --server-side-encryption-configuration '{"Rules":[{"ApplyServerSideEncryptionByDefault":{"SSEAlgorithm":"AES256"}}]}' --profile $env:AWS_PROFILE
```

4) Build the Spring Boot JAR using Dockerized Maven

```powershell
$proj      = (Get-Location).Path
$projUnix  = $proj -replace '^([A-Za-z]):','/$1' -replace '\\','/'
$mountProj = "${projUnix}:/app"
docker run --rm -v $mountProj -w /app maven:3.9-eclipse-temurin-17 mvn -q -DskipTests package
Copy-Item -Force .\target\javaonec2-0.0.1-SNAPSHOT.jar .\app.jar
```

5) Prepare v1 CodeDeploy bundle (appspec + scripts + env)

```powershell
"APP_VERSION=v1" | Set-Content -NoNewline app.env
Remove-Item -Recurse -Force bundle -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Force bundle | Out-Null
Copy-Item -Force app.jar,appspec.yml,app.env bundle\
Copy-Item -Recurse -Force scripts bundle\
$mountZip = "${projUnix}:/work"
docker run --rm -v $mountZip -w /work alpine:3.20 sh -lc "apk add --no-cache zip >/dev/null && cd bundle && zip -qr ../java-service-v1.zip ."
```

6) Upload bundle to S3 and create revision.json

```powershell
aws s3 cp .\java-service-v1.zip "s3://$env:S3_BUCKET/java-service/v1.zip" --region $env:AWS_REGION --profile $env:AWS_PROFILE
$BUCKET = $env:S3_BUCKET
$KEY    = "java-service/v1.zip"
$VERID  = (aws s3api list-object-versions --bucket $BUCKET --prefix $KEY --query "Versions[?Key=='$KEY']|[0].VersionId" --output text --region $env:AWS_REGION --profile $env:AWS_PROFILE).Trim()
$JSON   = '{"revisionType":"S3","s3Location":{"bucket":"'+$BUCKET+'","key":"'+$KEY+'","bundleType":"zip","version":"'+$VERID+'"}}'
Set-Content -NoNewline revision.json -Value $JSON
Get-Content revision.json
```

7) Deploy the CloudFormation stack (creates VPC, EC2, IAM, CodeDeploy, Budget)

```powershell
aws cloudformation deploy --stack-name "JavaService-dev" --template-file infra.yaml --capabilities CAPABILITY_NAMED_IAM --parameter-overrides ProjectName=JavaService Environment=dev ArtifactBucketName=$env:S3_BUCKET AppPort=80 InstanceType=t2.micro BudgetAmount=5 --region $env:AWS_REGION --profile $env:AWS_PROFILE
```

8) Enable auto-rollback on deployment failure

```powershell
aws deploy update-deployment-group --application-name JavaService-dev-app --current-deployment-group-name JavaService-dev-dg --auto-rollback-configuration enabled=true,events=DEPLOYMENT_FAILURE --region $env:AWS_REGION --profile $env:AWS_PROFILE
```

9) Create the v1 deployment and wait until it succeeds

```powershell
$DEPLOY_ID = aws deploy create-deployment --application-name JavaService-dev-app --deployment-group-name JavaService-dev-dg --revision file://revision.json --region $env:AWS_REGION --profile $env:AWS_PROFILE --query deploymentId --output text
aws deploy wait deployment-successful --deployment-id $DEPLOY_ID --region $env:AWS_REGION --profile $env:AWS_PROFILE
```

10) Verify service health and version

```powershell
$IID=(aws ec2 describe-instances --filters "Name=tag:App,Values=JavaService" "Name=instance-state-name,Values=running" --query "Reservations[0].Instances[0].InstanceId" --output text --region $env:AWS_REGION --profile $env:AWS_PROFILE).Trim()
$IP=(aws ec2 describe-instances --instance-ids $IID --query "Reservations[0].Instances[0].PublicIpAddress" --output text --region $env:AWS_REGION --profile $env:AWS_PROFILE).Trim()
Invoke-WebRequest -UseBasicParsing "http://$IP/health" | Select-Object StatusCode
Invoke-WebRequest -UseBasicParsing "http://$IP/version" | Select-Object StatusCode,Content
```

(Optional) Cleanup after demo

```powershell
aws cloudformation delete-stack --stack-name JavaService-dev --region $env:AWS_REGION --profile $env:AWS_PROFILE
aws cloudformation wait stack-delete-complete --stack-name JavaService-dev --region $env:AWS_REGION --profile $env:AWS_PROFILE
```
