& {
$ErrorActionPreference='Stop'
if($env:COMPUTERNAME -cne 'TEST-02' -or (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Cryptography').MachineGuid -cne '4f9cfa6d-48f6-4c66-a3a9-93e612f6bacb'){throw 'IDENTITY_MISMATCH'}
$parent=Join-Path $env:LOCALAPPDATA 'VentioFramework\Acceptance'
$root=Join-Path $parent ('io-race-'+[guid]::NewGuid().ToString('N'))
$user=[Security.Principal.WindowsIdentity]::GetCurrent().User
$acl=[Security.AccessControl.DirectorySecurity]::new();$acl.SetOwner($user);$acl.SetAccessRuleProtection($true,$false)
foreach($sid in @($user,[Security.Principal.SecurityIdentifier]::new('S-1-5-18'),[Security.Principal.SecurityIdentifier]::new('S-1-5-32-544'))){$acl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new($sid,'FullControl','ContainerInherit,ObjectInherit','None','Allow'))}
if(-not(Test-Path -LiteralPath $parent)){[IO.DirectoryInfo]::new($parent).Create($acl)}
[IO.DirectoryInfo]::new($root).Create($acl)
$helper='C:\Program Files\Ventio\host-payload\VentioHostService.exe'
$file=Join-Path $root 'concurrent.json'
function Start-Native([string]$operation,[string]$data){
 $info=[Diagnostics.ProcessStartInfo]::new();$info.FileName=$helper;$info.Arguments='--private-file-operation';$info.UseShellExecute=$false;$info.CreateNoWindow=$true;$info.RedirectStandardInput=$true;$info.RedirectStandardOutput=$true;$info.RedirectStandardError=$true
 $p=[Diagnostics.Process]::new();$p.StartInfo=$info;[void]$p.Start()
 $request=@{operation=$operation;path=$file;data=$data;ownerSid=$null;readerSid=$null}|ConvertTo-Json -Compress
 $p.StandardInput.Write($request);$p.StandardInput.Close();return $p
}
$reader=$null;$writer=$null
try {
 $create=Start-Native 'create' ('A'*262144);$o=$create.StandardOutput.ReadToEndAsync();$e=$create.StandardError.ReadToEndAsync();if(-not $create.WaitForExit(15000) -or $create.ExitCode -ne 0){throw 'FIXTURE_CREATE_FAILED'}
 $reader=Start-Native 'read' ''
 $first=[byte[]]::new(1);$read=$reader.StandardOutput.BaseStream.ReadAsync($first,0,1)
 if(-not $read.Wait(15000) -or $read.Result -ne 1){throw 'NATIVE_READER_DID_NOT_OPEN_FILE'}
 # The 349,528-byte encoded response cannot fit in the unread pipe. The native
 # helper is deterministically paused while its original read handle is open.
 $writer=Start-Native 'replace' 'replacement'
 $writerOut=$writer.StandardOutput.ReadToEndAsync();$writerError=$writer.StandardError.ReadToEndAsync()
 if(-not $writer.WaitForExit(15000)){throw 'WRITER_TIMEOUT'}
 $diagnostic=$writerError.GetAwaiter().GetResult()
 $remaining=$reader.StandardOutput.ReadToEndAsync();$readerError=$reader.StandardError.ReadToEndAsync()
 if(-not $reader.WaitForExit(15000)){throw 'READER_TIMEOUT'}
 $encoded=[Text.Encoding]::ASCII.GetString($first)+$remaining.GetAwaiter().GetResult()
 $snapshot=[Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($encoded))
 $report=[ordered]@{timestampUtc=[datetime]::UtcNow.ToString('o');machine='TEST-02';sourceCommit='246172799a44e16a4214f16ff0c2f6efdafc42bf';actualInstalledHelper=$true;readerHeldOpenThroughBoundedPipeBackpressure=$true;readerExitCode=$reader.ExitCode;readerSnapshotIntact=($snapshot -ceq ('A'*262144));writerExitCode=$writer.ExitCode;sharingViolation=($diagnostic -match 'VENTIO_PRIVATE_HELPER_FAILURE:replace_file:IOException:0x80070020');currentFileIsReplacement=([IO.File]::ReadAllText($file) -ceq 'replacement');businessDataTouched=$false}
 $report|ConvertTo-Json -Compress
}finally{
 foreach($p in @($reader,$writer)){if($p){if(-not $p.HasExited){$p.Kill()};$p.Dispose()}}
 if([IO.Path]::GetDirectoryName([IO.Path]::GetFullPath($root)) -cne [IO.Path]::GetFullPath($parent) -or (Get-Item -LiteralPath $root).Attributes -band [IO.FileAttributes]::ReparsePoint){throw 'CLEANUP_BOUNDARY_INVALID'}
 Remove-Item -LiteralPath $root -Recurse -Force
}
}

