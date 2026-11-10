param([switch] $Inspect, [switch] $ResumeBoundScope)
# One-time authorized diagnostic through the existing authenticated service pipe.
# Credentials remain in memory and in the service-owned durable receipt; no acknowledgement is sent.
$ErrorActionPreference = 'Stop'
$resultPath = 'C:\Program Files\Ventio\SetupStatus\maintenance-first-admin-diagnostic-20261031.json'
$result = @{ success=$false; status='failed'; failureCode='HOST_FIRST_ADMINISTRATOR_FAILED'; timestamp=[DateTime]::UtcNow.ToString('o') }
$pipe = $null
try {
  $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
  if (-not [Security.Principal.WindowsPrincipal]::new($identity).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) { throw 'Unauthorized' }
  $pending = Get-Content -LiteralPath (Join-Path $env:LOCALAPPDATA 'VentioFramework\host-setup-pending.json') -Raw | ConvertFrom-Json
  if ($pending.operationId -cne 'c5e5563e1eade9857513a8046aac4274' -or $pending.requesterSid -cne $identity.User.Value -or
      $pending.tenantId -cne 'Test-Business' -or $pending.companyId -cne 'Test-Company' -or $pending.branchId -cne 'Test-Office' -or
      (Get-FileHash -LiteralPath 'C:\Program Files\Ventio\host-payload\VentioHostService.exe' -Algorithm SHA256).Hash -notin @('129E4F4AB295FA161C32BE35C09F488107206250B9FAB6701D930A9F7B3113C3','16463268DE7BCB48AEC4F62A3D0CE850403B4D31E36B5CF1E804070ACEFA4431','4A1F1EA71E3DA41D528134CDA5C81F3A14C6E23F4794F599406568605C1E70C0')) { throw 'Target changed' }
  $service = Get-CimInstance Win32_Service -Filter "Name='VentioHost'"
  if ($service.StartName -cne 'NT SERVICE\VentioHost' -or $service.State -cne 'Running' -or (Get-Service VentioPostgres).Status -ne 'Running') { throw 'Service unavailable' }
  $pipe = [IO.Pipes.NamedPipeClientStream]::new('.', 'Ventio.Host.FirstAdmin.v1', [IO.Pipes.PipeDirection]::InOut,
    [IO.Pipes.PipeOptions]::Asynchronous, [Security.Principal.TokenImpersonationLevel]::Impersonation)
  $pipe.Connect(10000)
  $command = if ($Inspect) { @{operation='status'} } else { @{operation='bootstrap';tenantId=$pending.tenantId;companyId=$pending.companyId;branchId=$pending.branchId} }
  if ($ResumeBoundScope) { $command = @{operation='bootstrap';tenantId='Test-Project';companyId='Test-Company';branchId='Test-Branch'} }
  $request = $command | ConvertTo-Json -Compress
  $bytes = [Text.UTF8Encoding]::new($false).GetBytes($request + "`n")
  $pipe.Write($bytes,0,$bytes.Length); $pipe.Flush()
  $reader = [IO.StreamReader]::new($pipe,[Text.UTF8Encoding]::new($false),$false,1024,$true)
  try {
    $read = $reader.ReadLineAsync()
    if (-not $read.Wait(100000)) { throw 'Timeout' }
    $line = $read.Result
    if (-not $line -or $line.Length -gt 65536) { throw 'Invalid response' }
    $reply = $line | ConvertFrom-Json
    $codes = @('HOST_FIRST_ADMIN_REQUEST_INVALID','HOST_FIRST_ADMIN_DATABASE_CONNECTION_FAILED','HOST_FIRST_ADMIN_RECOVERY_AUTHORITY_FAILED',
      'HOST_FIRST_ADMIN_IDENTITY_BOOTSTRAP_FAILED','HOST_FIRST_ADMIN_HELPER_TIMEOUT','HOST_FIRST_ADMIN_RESULT_INVALID')
    if ($reply.success -isnot [bool] -or $reply.status -notin @('pending','acknowledged','failed','not-started')) { throw 'Invalid response' }
    $result.success = $reply.success
    $result.status = $reply.status
    if ($reply.failureCode -in $codes) { $result.failureCode = $reply.failureCode }
    elseif ($reply.success) { $result.failureCode = $null }
    if ($Inspect -and $reply.success -and $reply.scope) {
      $scope = @{}
      foreach ($name in @('tenantId','companyId','branchId')) {
        $value = $reply.scope.$name
        if ($value -isnot [string] -or $value.Length -gt 256 -or $value -match '[\x00-\x1F]') { throw 'Invalid scope' }
        $scope[$name] = $value
      }
      $result.scope = $scope
    }
    $reply = $null; $line = $null
  } finally { $reader.Dispose() }
}
catch { }
finally {
  if ($pipe) { $pipe.Dispose() }
  $result.timestamp = [DateTime]::UtcNow.ToString('o')
  [IO.File]::WriteAllText($resultPath,($result | ConvertTo-Json -Compress),[Text.UTF8Encoding]::new($false))
}
