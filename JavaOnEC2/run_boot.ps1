param(
    [int]$TimeoutSec=120,
    [int]$Port=8080
)

$proj='C:\Users\Akshat Sinha\Downloads\CLOUD COMPUTING\JavaOnEC2'
$gradlew=Join-Path $proj 'gradlew.bat'
$logOut=Join-Path $proj 'bootRun.out.log'
$logErr=Join-Path $proj 'bootRun.err.log'

if(Test-Path -LiteralPath $logOut){ Remove-Item -LiteralPath $logOut -Force -ErrorAction SilentlyContinue }
if(Test-Path -LiteralPath $logErr){ Remove-Item -LiteralPath $logErr -Force -ErrorAction SilentlyContinue }

$projQuoted='"'+$proj+'"'
$jvm='-Xms32m -Xmx128m -XX:+UseSerialGC --enable-native-access=ALL-UNNAMED'
$jvmProp='-Dspring-boot.run.jvmArguments='+'"'+$jvm+'"'
$p=Start-Process -FilePath $gradlew -ArgumentList @('-p',$projQuoted,'--no-daemon','bootRun',$jvmProp,'--stacktrace','--info') -WorkingDirectory $proj -RedirectStandardOutput $logOut -RedirectStandardError $logErr -PassThru

$sw=[System.Diagnostics.Stopwatch]::StartNew()
$deadline=(Get-Date).AddSeconds($TimeoutSec)
$started=$false

while((Get-Date) -lt $deadline){
    try {
        $r=Invoke-WebRequest -Uri "http://localhost:$Port/" -TimeoutSec 2 -SkipHttpErrorCheck -ErrorAction Stop
    } catch { $r=$null }
    if($r -and $r.StatusCode -ge 200 -and $r.StatusCode -lt 600){
        $started=$true; break
    }
    if($p.HasExited){ break }
    Start-Sleep -Milliseconds 500
}
$sw.Stop()
Write-Output ("RESULT="+($(if($started){'STARTED'}elseif($p.HasExited){'FAILED_EARLY'}else{'TIMEOUT'})))
Write-Output ("ELAPSED_MS="+$sw.ElapsedMilliseconds)

if(-not $p.HasExited){ Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue; Start-Sleep -Milliseconds 500 }

try {
    $conn=Get-NetTCPConnection -LocalPort $Port -ErrorAction SilentlyContinue | Where-Object State -eq Listen
    if($conn){ Stop-Process -Id $conn.OwningProcess -Force -ErrorAction SilentlyContinue }
}catch{}

"DONE"

