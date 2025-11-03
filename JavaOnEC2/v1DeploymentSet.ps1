$ErrorActionPreference='Stop'
$PSNativeCommandUseErrorActionPreference=$true
$ProgressPreference='Continue'
function Say($m){Write-Host ("==> {0}" -f $m) -ForegroundColor Cyan}
function Invoke-ProcProgress{
  param(
    [string]$File,
    [string]$Args,
    [string]$Title,
    [string]$LogPath,
    [int]$Id=1
  )
  if(-not $LogPath){$LogPath=Join-Path $PSScriptRoot 'logs/last.log'}
  $dir=[System.IO.Path]::GetDirectoryName($LogPath)
  if($dir -and -not (Test-Path $dir)){New-Item -ItemType Directory -Force $dir | Out-Null}
  if(Test-Path $LogPath){Remove-Item $LogPath -Force}
  $psi=New-Object System.Diagnostics.ProcessStartInfo
  $psi.FileName=$File
  $psi.Arguments=$Args
  $psi.RedirectStandardOutput=$true
  $psi.RedirectStandardError=$true
  $psi.UseShellExecute=$false
  $psi.CreateNoWindow=$true
  $p=New-Object System.Diagnostics.Process
  $p.StartInfo=$psi
  $null=$p.Start()
  $frames='|','/','-','\\'
  $i=0
  while(-not $p.HasExited){
    $frame=$frames[$i % $frames.Length]
    Write-Progress -Id $Id -Activity $Title -Status "Running $frame" -PercentComplete -1
    Start-Sleep -Milliseconds 120
    $i++
  }
  $out=$p.StandardOutput.ReadToEnd()
  $err=$p.StandardError.ReadToEnd()
  if($out){$out | Out-File -Encoding utf8 $LogPath -Append}
  if($err){$err | Out-File -Encoding utf8 $LogPath -Append}
  Write-Progress -Id $Id -Activity $Title -Completed
  if($p.ExitCode -ne 0){
    $tail = if(Test-Path $LogPath){Get-Content $LogPath -Tail 60 -ErrorAction SilentlyContinue}
    if($tail){Write-Host $tail}
    throw "$Title failed. See $LogPath"
  }
}

function New-ZipWithProgress{
  param(
    [Parameter(Mandatory)] [string]$SourceDir,
    [Parameter(Mandatory)] [string]$ZipPath,
    [int]$Id=10
  )
  Add-Type -AssemblyName System.IO.Compression.FileSystem
  if(Test-Path $ZipPath){ Remove-Item $ZipPath -Force }
  $files = Get-ChildItem -Path $SourceDir -Recurse -File
  $total = if($files){ $files.Count } else { 0 }
  $fs = [System.IO.File]::Open($ZipPath,[System.IO.FileMode]::Create)
  $zip = New-Object System.IO.Compression.ZipArchive($fs,[System.IO.Compression.ZipArchiveMode]::Create,$false)
  try{
    $i = 0
    foreach($f in $files){
      $rel = [System.IO.Path]::GetRelativePath($SourceDir,$f.FullName)
      $rel = $rel -replace '\\','/'
      $entry = $zip.CreateEntry($rel,[System.IO.Compression.CompressionLevel]::Optimal)
      $es = $entry.Open()
      try{
        $infs = [System.IO.File]::OpenRead($f.FullName)
        try { $infs.CopyTo($es) } finally { $infs.Dispose() }
      } finally { $es.Dispose() }
      $i++
      $percent = if($total -gt 0){ [int](($i*100)/$total) } else { 100 }
      Write-Progress -Id $Id -Activity 'Packaging bundle (zip)' -Status "$i of $total files" -PercentComplete $percent
    }
  } finally {
    $zip.Dispose(); $fs.Dispose()
  }
  Write-Progress -Id $Id -Activity 'Packaging bundle (zip)' -Completed
}

Say "Step 1: set AWS profile/region and verify identity, this method is also called as hydration of the terminal so that the aws cli responds well without error"
$env:AWS_PROFILE='java-ec2'
$env:AWS_REGION='us-east-1'
aws sts get-caller-identity --output json --region $env:AWS_REGION --profile $env:AWS_PROFILE | Out-String | Write-Host

Say "Step 2: compute S3 artifact bucket"
$acct=(aws sts get-caller-identity --query Account --output text --region $env:AWS_REGION --profile $env:AWS_PROFILE).Trim()
$env:S3_BUCKET=("java-ec2-artifacts-{0}-{1}" -f $acct,$env:AWS_REGION).ToLower()
Write-Host "Bucket: $env:S3_BUCKET"

Say "Step 3: create/secure bucket (idempotent)"
try{
  if($env:AWS_REGION -eq 'us-east-1'){
    aws s3api create-bucket --bucket $env:S3_BUCKET --region $env:AWS_REGION --profile $env:AWS_PROFILE | Out-Null
  }else{
    aws s3api create-bucket --bucket $env:S3_BUCKET --region $env:AWS_REGION --create-bucket-configuration LocationConstraint=$env:AWS_REGION --profile $env:AWS_PROFILE | Out-Null
  }
}catch{Write-Host 'Bucket may already exist—continuing'}
aws s3api put-bucket-versioning --bucket $env:S3_BUCKET --versioning-configuration Status=Enabled --profile $env:AWS_PROFILE
aws s3api put-public-access-block --bucket $env:S3_BUCKET --public-access-block-configuration BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true --profile $env:AWS_PROFILE
aws s3api put-bucket-encryption --bucket $env:S3_BUCKET --server-side-encryption-configuration '{\"Rules\":[{\"ApplyServerSideEncryptionByDefault\":{\"SSEAlgorithm\":\"AES256\"}}]}' --profile $env:AWS_PROFILE

Say "Step 4: build jar (Dockerized Maven)"
$proj=(Get-Location).Path
$projUnix=$proj -replace '^([A-Za-z]):','/$1' -replace '\\','/'
$mountProj="${projUnix}:/app"
docker volume create m2repo | Out-Null
docker run --rm -v $mountProj -v m2repo:/root/.m2 -w /app maven:3.9-eclipse-temurin-17 mvn -q -DskipTests -T 1C package
Copy-Item -Force .\target\javaonec2-0.0.1-SNAPSHOT.jar .\app.jar

Say "Step 5: prepare v1 bundle"
"APP_VERSION=v1" | Set-Content -NoNewline app.env
Remove-Item -Recurse -Force bundle -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Force bundle | Out-Null
Copy-Item -Force app.jar,appspec.yml,app.env bundle\
Copy-Item -Recurse -Force scripts bundle\
$bundleDir = Join-Path (Get-Location).Path 'bundle'
New-ZipWithProgress -SourceDir $bundleDir -ZipPath (Join-Path (Get-Location).Path 'java-service-v1.zip') -Id 10

Say "Step 6: upload artifact and record VersionId"
aws s3 cp .\java-service-v1.zip "s3://$env:S3_BUCKET/java-service/v1.zip" --region $env:AWS_REGION --profile $env:AWS_PROFILE | Out-Null
$BUCKET=$env:S3_BUCKET; $KEY='java-service/v1.zip'
$VERID=(aws s3api list-object-versions --bucket $BUCKET --prefix $KEY --query 'Versions[0].VersionId' --output text --region $env:AWS_REGION --profile $env:AWS_PROFILE).Trim()
$JSON='{"revisionType":"S3","s3Location":{"bucket":"'+$BUCKET+'","key":"'+$KEY+'","bundleType":"zip","version":"'+$VERID+'"}}'
Set-Content -NoNewline revision.json -Value $JSON
Get-Content revision.json | Write-Host

Say "Step 7: deploy CloudFormation stack"
# Using direct CLI call to avoid any argument parsing issues under the progress wrapper
aws cloudformation deploy --stack-name "JavaService-dev" --template-file infra.yaml --capabilities CAPABILITY_NAMED_IAM --parameter-overrides ProjectName=JavaService Environment=dev ArtifactBucketName=$env:S3_BUCKET AppPort=80 InstanceType=t2.micro BudgetAmount=5 --region $env:AWS_REGION --profile $env:AWS_PROFILE

Say "Step 8: enable auto-rollback"
aws deploy update-deployment-group --application-name JavaService-dev-app --current-deployment-group-name JavaService-dev-dg --auto-rollback-configuration enabled=true,events=DEPLOYMENT_FAILURE --region $env:AWS_REGION --profile $env:AWS_PROFILE

Say "Step 9: create deployment and wait until success"
$DEPLOY_ID=aws deploy create-deployment --application-name JavaService-dev-app --deployment-group-name JavaService-dev-dg --revision file://revision.json --region $env:AWS_REGION --profile $env:AWS_PROFILE --query deploymentId --output text
Write-Host "DeploymentId: $DEPLOY_ID"
aws deploy wait deployment-successful --deployment-id $DEPLOY_ID --region $env:AWS_REGION --profile $env:AWS_PROFILE

Say "Step 10: verify health and version"
$IID=(aws ec2 describe-instances --filters "Name=tag:App,Values=JavaService" "Name=instance-state-name,Values=running" --query "Reservations[0].Instances[0].InstanceId" --output text --region $env:AWS_REGION --profile $env:AWS_PROFILE).Trim()
$IP=(aws ec2 describe-instances --instance-ids $IID --query "Reservations[0].Instances[0].PublicIpAddress" --output text --region $env:AWS_REGION --profile $env:AWS_PROFILE).Trim()
$h=(Invoke-WebRequest -UseBasicParsing "http://$IP/health").StatusCode
$v=Invoke-WebRequest -UseBasicParsing "http://$IP/version"
Write-Host "Health: $h"
Write-Host ("Version: {0}" -f $v.Content)

Write-Host 'Done: v1 deployment complete.' -ForegroundColor Green
