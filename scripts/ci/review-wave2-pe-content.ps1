$ErrorActionPreference='Stop'
if($env:GITHUB_ACTIONS -cne 'true' -or $env:RUNNER_ENVIRONMENT -cne 'github-hosted'){throw 'Hosted data-only review required'}
$context=Get-Content -LiteralPath $env:VENTIO_VERIFY_CONTEXT -Raw|ConvertFrom-Json
$out=Split-Path -Parent $env:VENTIO_VERIFY_CONTEXT
$root=[IO.Path]::GetFullPath($context.payload)
$rows=@()
foreach($file in Get-ChildItem -LiteralPath $root -Recurse -File){
  if($file.Length -lt 64){continue}
  $stream=[IO.File]::Open($file.FullName,'Open','Read','Read')
  try {
    $reader=[IO.BinaryReader]::new($stream)
    if($reader.ReadUInt16() -ne 0x5a4d){continue}
    $stream.Position=0x3c
    $offset=$reader.ReadUInt32()
    if($offset -lt 64 -or $offset -gt ($file.Length-24) -or $offset -gt 16777216){continue}
    $stream.Position=$offset
    if($reader.ReadUInt32() -ne 0x4550){continue}
    $machine=$reader.ReadUInt16()
  } finally {$stream.Dispose()}
  $relative=[IO.Path]::GetRelativePath($root,$file.FullName).Replace('\','/')
  $signature=Get-AuthenticodeSignature -LiteralPath $file.FullName
  $rows += [pscustomobject]@{path=$relative;sha256=(Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash.ToLowerInvariant();machine=('0x{0:x4}' -f $machine);status=$signature.Status.ToString();publisher=$signature.SignerCertificate.Subject;fileVersion=$file.VersionInfo.FileVersion}
}
$original=@(Get-Content -LiteralPath (Join-Path $root 'Evidence/executable-signatures.json') -Raw|ConvertFrom-Json)
$additional=@($rows|Where-Object {$_.path -notin $original.path})
$unexpected=@($additional|Where-Object path -cne 'Client/data/app.so')
$invalid=@($rows|Where-Object status -notin @('Valid','NotSigned'))
$missing=@($original|Where-Object {$_.path -notin $rows.path})
$mismatch=@($original|Where-Object {$entry=$_;@($rows|Where-Object {$_.path -ceq $entry.path -and $_.sha256 -ceq $entry.sha256 -and $_.status -ceq $entry.status}).Count -ne 1})
$report=[ordered]@{identity=$context.identity;candidateCommit=$context.candidateCommit;reviewCommit=$env:GITHUB_SHA;status=$(if($unexpected.Count -or $invalid.Count -or $missing.Count -or $mismatch.Count){'BLOCKED'}else{'STATIC_PE_INVENTORY_VERIFIED'});signatureInspectionOnly=$true;productExecuted=$false;standardExtensionInventoryCount=$original.Count;portableExecutableCount=$rows.Count;additionalExecutablePaths=@($additional.path);unexpectedExecutablePaths=@($unexpected.path);invalidSignatures=@($invalid.path);missingOriginalPaths=@($missing.path);originalInventoryMismatches=@($mismatch.path);files=$rows;securityClearance='NOT_ESTABLISHED_BY_SIGNATURES_OR_HASHES'}
$report|ConvertTo-Json -Depth 6|Set-Content -LiteralPath (Join-Path $out 'pe-header-inventory.json')
if($report.status -ne 'STATIC_PE_INVENTORY_VERIFIED'){throw 'Unexpected PE content or signature mismatch; see retained inventory'}
Write-Output ('Inspected '+$rows.Count+' PE headers/signatures without executing a product; supplementary paths: '+($additional.path -join ','))
