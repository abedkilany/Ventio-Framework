# SSH-only physical device verification — 2026-11-09

Development address was `192.168.1.104`; command working directory was `C:\Users\User\Desktop\Ventio Framework`. Connections used the existing SSH identity with batch mode, host-key checking and explicit remote PowerShell. Both returned exit 0. No service or application data mutation was performed.

| Observation | Host | Client |
|---|---|---|
| IPv4 | 192.168.1.102 | 192.168.1.105 |
| Win32_ComputerSystemProduct UUID | 4C4C4544-0051-5A10-8042-C4C04F343032 | 9EB7F117-F40D-11DE-81D0-B9F76E398C6C |
| SSH principal | ABEDKILANY\abedkilany | ABEDKILANY\abedkilany |
| Administrative token | High Integrity `S-1-16-12288` | High Integrity `S-1-16-12288` |
| `sshd` | Running / Auto / LocalSystem | Running / Auto / LocalSystem |
| `VentioHost` | Running / Auto / NT SERVICE\VentioHost | Absent |
| `VentioPostgres` | Running / Auto / NT SERVICE\VentioPostgres | Absent |

The UUID and IPv4 establish separate physical computers despite duplicate hostname text. The SSH identity is a Windows principal. Ventio authorization requires a valid application credential.
