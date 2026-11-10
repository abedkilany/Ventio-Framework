# Host Reboot Connectivity Investigation — 2026-11-09

## Current authenticated status

Development (`192.168.1.104`) connected to Host (`192.168.1.102`) over SSH using the existing `ventio_lab` key. The SSH command exited 0. Remote checks returned:

```text
HOSTNAME=ABEDKILANY
WHOAMI=ABEDKILANY\AbedKilany
ADMIN=True
Mandatory Label\High Mandatory Level  S-1-16-12288
LASTBOOT=2026-11-09T12:47:20.5000000+02:00
SERVICE=sshd|Running|Auto|LocalSystem
SERVICE=VentioHost|Running|Auto|NT SERVICE\VentioHost
SERVICE=VentioPostgres|Running|Auto|NT SERVICE\VentioPostgres
LISTENER=0.0.0.0:22
LISTENER=0.0.0.0:3389
LISTENER=0.0.0.0:8443
INSTALLED=Ventio|0.1.18
```

From Development, `curl.exe --cacert` with the previously fingerprint-verified Host LAN certificate to `https://192.168.1.102:8443/healthz` returned `{"apiVersion":1,"status":"alive"}`, HTTP 200, TLS verify result 0. This is pinned TLS and liveness evidence only; it is not authenticated application readiness.

## Reboot and connectivity chronology

Times below are Host local time (UTC+02:00), from the Host System and operational event logs:

| Time | Evidence | Result |
|---|---|---|
| 12:46:52 | System / User32 event 1074 | Controlled restart requested by `shutdown.exe`, initiated by `ABEDKILANY\AbedKilany`. |
| 12:47:20 | `Win32_OperatingSystem.LastBootUpTime` | New boot. |
| 12:47:12 | System / SCM event 7034 | OpenSSH service terminated during shutdown. |
| 12:47:34 | OpenSSH/Operational | sshd listening on `::` and `0.0.0.0`, port 22. |
| 12:47:44 | WLAN AutoConfig events 11001/11005/8001 | Intel Dual Band Wireless-AC 3160 associated to SSID `AbedKilany`; WPA2 security succeeded. |
| 12:47:50 | NetworkProfile events 4002/10000 | Wi-Fi profile `AbedKilany` identified and connected as Private. |
| 12:47:54 | OpenSSH/Operational event 4 | Public-key login from Development succeeded for `abedkilany`. |
| 12:48:12–13 | Kernel-Power event 566, then event 42 | System session entered `ScreenOffGracePeriod`; Windows entered sleep with `Sleep Reason: Button or Lid`. |
| 12:48:13 | WLAN AutoConfig 11004 and NetworkProfile 10001 | Wi-Fi security stopped and the `AbedKilany` network disconnected. The associated System/NETwNb64 event 8000 has no retrievable message text. |
| 13:19:10 | WLAN AutoConfig events 11001/11005/8001 | Wi-Fi association/security succeeded again. |
| 13:19:06 | Power-Troubleshooter event 1 | System returned from low power state; wake source `Power Button`. |
| 13:19:13 | Kernel-Power event 42; WLAN AutoConfig 11004; NetworkProfile 10001 | Seven seconds after wake, Windows entered sleep with `Sleep Reason: Button or Lid`; Wi-Fi security stopped and network disconnected again. |
| 13:20:38–39 | Power-Troubleshooter event 1 | System returned from low power state; wake source `Power Button`. |
| 13:20:38 | System/NETwNb64 event 7036 | Wireless driver service state event. |
| 13:20:41–42 | WLAN AutoConfig and DHCP-Client/Admin | Wi-Fi association/security succeeded; DHCP network SSID was accepted from cache. |
| 13:20:42 | `Win32_NetworkAdapterConfiguration` | Wi-Fi DHCP lease obtained for `192.168.1.102` from `192.168.1.1`, expiry 2026-11-10 13:20:42. |
| 13:20:43 | NetworkProfile events 4002/10000 | Wi-Fi became identified and connected as Private with IPv4 Internet. |

Current adapter check reports Wi-Fi Up on the Intel AC 3160 at 150 Mbps, IP `192.168.1.102`, gateway/DHCP server `192.168.1.1`; Ethernet is disconnected. The sampled OpenSSH events contain successful key-auth entries and no failed public-key authentication. sshd was listening and had accepted the key before the later wireless disconnection.

## Finding and limits

The outage was not a persistent sshd startup or key-auth failure. The Host entered system sleep at 12:48:13.393; Kernel-Power event 42 gives `Sleep Reason: Button or Lid`. Power-Troubleshooter event 1 says it woke at 13:19:06 from the Power Button. Seven seconds later, it entered sleep again at 13:19:13.706 with the same `Button or Lid` reason and woke at 13:20:38 from the Power Button. The WLAN report summarizes one disconnect as driver-initiated and one as requested to establish a new connection. At both sleep transitions, NDIS reports a system-resume / device-operational sequence followed by a low-power request; WLAN security stopped and the network profile disconnected. The current DHCP lease was not obtained until 13:20:42.

This establishes Windows sleep/power transitions as the cause class for the prolonged network loss. It does not distinguish whether each sleep was triggered by the lid sensor or power button, because Windows combines them in the event reason. The active Balanced plan reports `Sleep after` set to zero for AC and battery, so the configured idle timeout is not the observed trigger. Host chassis type is 8 (portable), and battery status reports AC online. No power, network, service, or Ventio setting was changed. The Host's driver event text remains unavailable; the raw binary payload was not interpreted.

The Host services and pinned HTTPS liveness are currently verified. A pinned TLS POST to `/api/v1/management/readiness` without a bearer token returned HTTP 401 `UNAUTHENTICATED`, correlation ID `cor_5155fe4fc4906d4d22f06c7019b3ecd6`; this confirms the live route's authentication gate and does not provide readiness. The source contract requires a bearer token backed by a persistent identity with exact-scope `host.status.read`; no valid session was available through the UI. Computer Use later opened Remote Desktop using its saved Host connection and reached a window titled `192.168.1.102 - Remote Desktop Connection`. Read-only `quser` over SSH reports user `abedkilany`, session `rdp-tcp#0`, ID 2, state `Active`. Computer Use screenshot capture then failed with `foreground window did not report a process id`, including after selecting a fresh window handle. No credential was entered manually or setup state modified.

## Acceptance effect

The Windows WLAN diagnostic report is located on Host at `C:\ProgramData\Microsoft\Windows\WlanReport\wlan-report-latest.html` (generated 2026-11-09 14:23 local). It is retained in place because it includes WLAN profile material; only event timing, summary disconnect-reason labels, and adapter metadata were inspected, and the report was not copied into this workspace.

## Correction and controlled reboot regression — 2026-11-09

The Host is a dedicated portable test machine, AC-online. The active Balanced power plan had both `Lid close action` and `Power button action` set to index `1` (`Sleep`) on AC and DC; the AC/DC idle `Sleep after` indices were both `0` (`Never`). To prevent the verified physical-button/lid sleep class from interrupting acceptance when the Host is plugged in, only the two AC actions were changed to index `0` (`Do nothing`). The two DC actions remain at index `1` (`Sleep`). No service, network, Ventio, or database configuration was changed.

The corrected AC settings were read back before reboot. A planned reboot command returned exit 0. The first bounded recovery attempt connected over SSH and verified `ABEDKILANY`, `abedkilany\\AbedKilany`, all three services Running/Automatic, and ports 22/3389/8443 listening. Pinned HTTPS `/healthz` returned `{"apiVersion":1,"status":"alive"}`, HTTP 200, TLS verify 0. After waiting past the previous ~53-second post-boot sleep point, a second authenticated SSH check showed High Integrity SID `S-1-16-12288`, services still Running/Automatic, AC actions still index 0 and DC actions still index 1, and `POSTBOOT_SLEEP=NONE` in Kernel-Power event 42 checks since boot. Pinned HTTPS again returned HTTP 200/TLS 0. This is a `PASS — VERIFIED` reboot/sleep-policy regression; it does not prove authenticated Host readiness.

Computer Use reconnected to the RDP window after reboot, but screenshot capture failed twice with `IGraphicsCaptureItemInterop.CreateForMonitor failed: Could not capture the given monitor. (0x80070057)`. The Host Overview remains visually unverified.

The previous “Host reboot unavailable” block is superseded for current reachability and service-start checks. The sleep reason and wake source are identified to the Windows `Button or Lid` / Power Button event classes; which physical control caused each sleep remains unknown. This evidence does not by itself close Stage 10's full installed lifecycle criteria, Stage 3's installed first-admin/resume criteria, or Stage 8's physical enrollment-to-receipt/readback sequence. Accepted Wave 1 remains 60%; Stages 10, 3, 8 and 9 remain open.
