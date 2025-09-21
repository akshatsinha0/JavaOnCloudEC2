$ErrorActionPreference='Stop'
$PSNativeCommandUseErrorActionPreference=$true
$ProgressPreference='Continue'
function Say($m){Write-Host ("==> {0}" -f $m) -ForegroundColor Cyan}

function New-ZipWithProgress{
  param(
    [Parameter(Mandatory)] [string]$SourceDir,
    [Parameter(Mandatory)] [string]$ZipPath,
    [int]$Id=20
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
      Write-Progress -Id $Id -Activity 'Packaging v2 bundle (zip)' -Status "$i of $total files" -PercentComplete $percent
    }
  } finally {
    $zip.Dispose(); $fs.Dispose()
  }
  Write-Progress -Id $Id -Activity 'Packaging v2 bundle (zip)' -Completed
}

Say "Step 1: set AWS profile/region and verify identity"
$env:AWS_PROFILE='java-ec2'
$env:AWS_REGION='us-east-1'
aws sts get-caller-identity --output json --region $env:AWS_REGION --profile $env:AWS_PROFILE | Out-String | Write-Host

Say "Step 2: ensure S3 artifact bucket (reuse from v1)"
$acct=(aws sts get-caller-identity --query Account --output text --region $env:AWS_REGION --profile $env:AWS_PROFILE).Trim()
$env:S3_BUCKET=("java-ec2-artifacts-{0}-{1}" -f $acct,$env:AWS_REGION).ToLower()
Write-Host "Bucket: $env:S3_BUCKET"

Say "Step 3: build jar quickly (Dockerized Maven with cache)"
$proj=(Get-Location).Path
$projUnix=$proj -replace '^([A-Za-z]):','/$1' -replace '\\','/'
$mountProj="${projUnix}:/app"
docker volume create m2repo | Out-Null
docker run --rm -v $mountProj -v m2repo:/root/.m2 -w /app maven:3.9-eclipse-temurin-17 mvn -q -DskipTests -T 1C package
Copy-Item -Force .\target\javaonec2-0.0.1-SNAPSHOT.jar .\app.jar

Say "Step 4: prepare v2 bundle (force ValidateService to fail)"
"APP_VERSION=v2" | Set-Content -NoNewline app.env
Remove-Item -Recurse -Force bundle -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Force bundle | Out-Null
Copy-Item -Force app.jar,appspec.yml,app.env bundle\
# Copy scripts and overwrite validate.sh to fail deliberately without changing repo files
New-Item -ItemType Directory -Force bundle\scripts | Out-Null
Copy-Item -Recurse -Force .\scripts\* bundle\scripts\
@'
#!/bin/bash
exit 1
'@ | Set-Content -NoNewline -Encoding ascii bundle\scripts\validate.sh

# Zip as v2
$bundleDir = Join-Path (Get-Location).Path 'bundle'
New-ZipWithProgress -SourceDir $bundleDir -ZipPath (Join-Path (Get-Location).Path 'java-service-v2.zip') -Id 20

Say "Step 5: upload v2 and write revision.json"
aws s3 cp .\java-service-v2.zip "s3://$env:S3_BUCKET/java-service/v2.zip" --region $env:AWS_REGION --profile $env:AWS_PROFILE | Out-Null
$BUCKET=$env:S3_BUCKET; $KEY='java-service/v2.zip'
$VERID=(aws s3api list-object-versions --bucket $BUCKET --prefix $KEY --query "Versions[?Key=='$KEY']|[0].VersionId" --output text --region $env:AWS_REGION --profile $env:AWS_PROFILE).Trim()
$JSON='{"revisionType":"S3","s3Location":{"bucket":"'+$BUCKET+'","key":"'+$KEY+'","bundleType":"zip","version":"'+$VERID+'"}}'
Set-Content -NoNewline revision.json -Value $JSON
Get-Content revision.json | Write-Host

Say "Step 6: ensure auto-rollback is enabled"
aws deploy update-deployment-group --application-name JavaService-dev-app --current-deployment-group-name JavaService-dev-dg --auto-rollback-configuration enabled=true,events=DEPLOYMENT_FAILURE --region $env:AWS_REGION --profile $env:AWS_PROFILE | Out-Null

Say "Step 7: create v2 deployment (expected to fail)"
$DEPLOY_ID=aws deploy create-deployment --application-name JavaService-dev-app --deployment-group-name JavaService-dev-dg --revision file://revision.json --region $env:AWS_REGION --profile $env:AWS_PROFILE --query deploymentId --output text
Write-Host "DeploymentId: $DEPLOY_ID"
# Poll deployment status until it is Failed (expected) or Succeeded (unexpected)
$max=120; $st='';
for($i=0;$i -lt $max;$i++){
  $st=(aws deploy get-deployment --deployment-id $DEPLOY_ID --query "deploymentInfo.status" --output text --region $env:AWS_REGION --profile $env:AWS_PROFILE).Trim()
  Write-Host ("Status: {0}" -f $st)
  if($st -eq 'Failed' -or $st -eq 'Succeeded'){ break }
  Start-Sleep -Seconds 5
}
if($st -ne 'Failed'){
  throw "Expected deployment to Fail for rollback demo, but status=$st"
}

Say "Step 8: verify rollback kept v1 running"
$IID=(aws ec2 describe-instances --filters "Name=tag:App,Values=JavaService" "Name=instance-state-name,Values=running" --query "Reservations[0].Instances[0].InstanceId" --output text --region $env:AWS_REGION --profile $env:AWS_PROFILE).Trim()
$IP=(aws ec2 describe-instances --instance-ids $IID --query "Reservations[0].Instances[0].PublicIpAddress" --output text --region $env:AWS_REGION --profile $env:AWS_PROFILE).Trim()
$ok=$false
for($i=0;$i -lt 60;$i++){
  try{
    $resp=Invoke-WebRequest -UseBasicParsing "http://$IP/version" -TimeoutSec 3
    Write-Host ("Version after failed v2 deploy (should be v1): {0}" -f $resp.Content)
    $ok=$true; break
  }catch{
    Start-Sleep -Seconds 3
  }
}
if(-not $ok){ Write-Host 'Service not responding yet after rollback; try again in a few seconds.' -ForegroundColor Yellow }

Write-Host 'Done: v2 failure & rollback demo complete.' -ForegroundColor Green