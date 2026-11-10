# Pinned development update of the service's authenticated, read-only status operation.
$ErrorActionPreference='Stop'
$source='C:\Users\User\Desktop\Ventio Framework\packages\ventio_host_api\build\windows\host-reply-delivery-20261031\VentioHostService.exe'
$target='C:\Program Files\Ventio\host-payload\VentioHostService.exe'
$manifestPath='C:\Program Files\Ventio\host-payload\payload-manifest.json'
$status='C:\Program Files\Ventio\SetupStatus\maintenance-status-update-20261031.json'
$sc=Join-Path $env:SystemRoot 'System32\sc.exe'
$phase='PREFLIGHT'
try {
  if((Get-FileHash $source -Algorithm SHA256).Hash -ne '309AFC2E2530913E7913BFB53BD2E24A7759AC1BD90D052DC06C97DE015B034E' -or
    (Get-FileHash $target -Algorithm SHA256).Hash -ne '4A1F1EA71E3DA41D528134CDA5C81F3A14C6E23F4794F599406568605C1E70C0'){throw 'PINNED_BINARY_MISMATCH'}
  $service=Get-CimInstance Win32_Service -Filter "Name='VentioHost'"
  if($service.State -cne 'Running' -or $service.StartName -cne 'NT SERVICE\VentioHost' -or
    (Get-Service VentioPostgres).Status -ne 'Running'){throw 'SERVICE_STATE_CHANGED'}
  $children=@((Get-CimInstance Win32_Process) | Where-Object ParentProcessId -eq $service.ProcessId)
  foreach($child in $children){if($child.Name -cne 'ventio_host.exe' -or $child.ExecutablePath -cne 'C:\Program Files\Ventio\host-payload\ventio_host.exe'){throw 'UNEXPECTED_SERVICE_CHILD'}}
  if(Get-Process ventio_native_client,ventio_identity_bootstrap -ErrorAction SilentlyContinue){throw 'HOST_MUST_BE_IDLE'}
  $backup=Join-Path 'C:\ProgramData\Ventio\RecoveryEvidence' ('first-admin-status-' + [Guid]::NewGuid().ToString('N'))
  [IO.Directory]::CreateDirectory($backup) | Out-Null
  $acl=[Security.AccessControl.DirectorySecurity]::new(); $acl.SetAccessRuleProtection($true,$false)
  foreach($sid in @('S-1-5-18','S-1-5-32-544')){$acl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new([Security.Principal.SecurityIdentifier]::new($sid),'FullControl','ContainerInherit,ObjectInherit','None','Allow'))}
  Set-Acl -LiteralPath $backup -AclObject $acl
  Copy-Item -LiteralPath $target -Destination (Join-Path $backup 'VentioHostService.exe')
  Copy-Item -LiteralPath $manifestPath -Destination (Join-Path $backup 'payload-manifest.json')
  $phase='STOP'; & $sc stop VentioHost | Out-Null
  if($LASTEXITCODE -ne 0){throw 'STOP_FAILED'}
  (Get-Service VentioHost).WaitForStatus('Stopped',[TimeSpan]::FromSeconds(20))
  $phase='UPDATE'
  Copy-Item -LiteralPath $source -Destination $target -Force
  $manifest=Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
  $entry=@($manifest.verifiedFiles | Where-Object path -ceq 'VentioHostService.exe')
  if($entry.Count -ne 1){throw 'MANIFEST_INVALID'}
  $entry[0].length=(Get-Item $target).Length
  $entry[0].sha256='309afc2e2530913e7913bfb53bd2e24a7759ac1bd90d052dc06c97de015b034e'
  [IO.File]::WriteAllText($manifestPath,($manifest | ConvertTo-Json -Depth 12),[Text.UTF8Encoding]::new($false))
  $phase='START'; & $sc start VentioHost | Out-Null
  if($LASTEXITCODE -ne 0){throw 'START_FAILED'}
  (Get-Service VentioHost).WaitForStatus('Running',[TimeSpan]::FromSeconds(30))
  [IO.File]::WriteAllText($status,'{"state":"complete","code":"FIRST_ADMIN_STATUS_UPDATE_PASS"}')
}
catch {
  [IO.File]::WriteAllText($status,(@{state='failed';phase=$phase;code='FIRST_ADMIN_STATUS_UPDATE_FAILED'} | ConvertTo-Json -Compress))
  if((Get-Service VentioHost).Status -eq 'Stopped'){& $sc start VentioHost | Out-Null}
  exit 1
}
