& {
$ErrorActionPreference='Stop'
if($env:COMPUTERNAME -cne 'VENTIO-TEST-01' -or (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Cryptography').MachineGuid -cne 'e1bd301b-05eb-4b3f-9b40-2c899ae39ae8'){throw 'IDENTITY_MISMATCH'}
Add-Type -TypeDefinition @'
using System;
using System.IO;
using System.Net.Security;
using System.Net.Sockets;
using System.Security.Authentication;
using System.Security.Cryptography;
using System.Text;
public static class VentioPinnedHealthProbe {
 public static string Read(string pin) {
  using(var tcp=new TcpClient()) {
   var connecting=tcp.ConnectAsync("192.168.1.108",8443);
   if(!connecting.Wait(10000)) throw new TimeoutException(); connecting.GetAwaiter().GetResult();
   using(var tls=new SslStream(tcp.GetStream(),false,(sender,certificate,chain,errors)=> {
    if(certificate==null) return false;
    using(var sha=SHA256.Create()) return BitConverter.ToString(sha.ComputeHash(certificate.GetRawCertData())).Replace("-","").ToLowerInvariant()==pin;
   })) {
    tls.ReadTimeout=10000;tls.WriteTimeout=10000;
    tls.AuthenticateAsClient("192.168.1.108",null,SslProtocols.Tls12,false);
    var request=Encoding.ASCII.GetBytes("GET /healthz HTTP/1.1\r\nHost: 192.168.1.108:8443\r\nConnection: close\r\n\r\n");
    tls.Write(request,0,request.Length);tls.Flush();
    using(var reader=new StreamReader(tls,Encoding.UTF8)) {
     var response=reader.ReadToEnd();if(response.Length>16384)throw new InvalidDataException();return response;
    }
   }
  }
 }
}
'@
$pin='fc5c6bdf70d631a5863897d4af6620642cfff4875a53a3b433a3b2eb0083f4cc'
$wrongPinDenied=$false
try{[void][VentioPinnedHealthProbe]::Read(('0'*64))}catch{$wrongPinDenied=$true}
if(-not $wrongPinDenied){throw 'WRONG_PIN_ADMITTED'}
$response=[VentioPinnedHealthProbe]::Read($pin)
$parts=$response.Split(@("`r`n`r`n"),2,[StringSplitOptions]::None)
if($parts.Count -ne 2 -or $parts[0] -notmatch '^HTTP/1.1 200 ' -or $parts[1] -notmatch '"status":"alive"'){throw 'ACTUAL_REMOTE_HOST_HEALTH_FAILED'}
[ordered]@{timestampUtc=[datetime]::UtcNow.ToString('o');clientMachine=$env:COMPUTERNAME;hostMachine='TEST-02';endpoint='https://192.168.1.108:8443';exactCertificateSha256=$pin;wrongPinDenied=$wrongPinDenied;actualPinnedHostHealthSucceeded=$true;anonymousBusinessAccessClaimed=$false;offlineSyncAcceptanceClaimed=$false;osTrustStoreChanged=$false}|ConvertTo-Json -Compress
}

