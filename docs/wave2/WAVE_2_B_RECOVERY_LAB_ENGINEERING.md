# Recovery-lab engineering implementation — 2026-11-19

Scope: `feature/wave-2-a`, PR #6 Draft/unmerged; Wave_2_C closed. Source work and
targeted GitHub-hosted execution only. No owner VM/BAHAA configuration changed,
no TEST-01/02 access, Ventio installation or P001–P006 execution occurred. The
[initial plan](WAVE_2_B_RECOVERY_LAB_IMPLEMENTATION_PLAN.md) and read-only
observations are retained; this report supersedes its planning-only status.

## Implementations

- **Identity:** `RecoveryLabAdmission.psm1` checks the independent owner-approved
  admission digest, preserved host denial, existing disposable hostname rule,
  exact MachineGuid/SMBIOS UUID, virtual hardware, single adapter MAC, management
  VMId and SSH pin. Management evidence is independent input, not guest
  authentication of Hyper-V. Live admission requires normal administrator
  elevation and AllSigned. Both installed entry points use it; markers add SMBIOS
  and admission digest binding. Existing opt-in, scope, private ACL, source/payload/
  witness checks and both destructive-operation switches remain.
- **Isolation:** `RecoveryLabIsolation.psm1` and
  `prepare-recovery-lab-isolation.ps1` export a hash-pinned eight-rule plan for one
  adapter: stateful management SSH, bounded DHCP, IPv4/IPv6 default denial, no
  general egress. Apply requires explicit approval, exact preserved management-host
  identity, elevation, VMId/MAC/switch/address checks and empty prior ACLs. Rollback
  accepts only matching owned rules, refuses foreign/concurrent changes and removes
  denies before SSH. CI tests planning/rollback logic; **effective Hyper-V
  enforcement and actual rollback are unexecuted**, requiring approved VM setup.
- **Signing:** `SignHostScripts.psm1`, reusable hosted signing workflow and staging
  script enforce the publisher pin, private key/EKU/validity, SHA-256 Authenticode,
  release timestamp and signature verification, retaining source/distributed
  hashes. Only hosted-runner staged copies can be signed. Host builder signs copied
  scripts before hashes/manifests when selected; strict mode refuses missing
  identity. The reusable workflow also signs a companion tooling artifact. Normal
  installer/broker/task `-File` execution still has no execution-policy override.
  No trusted publisher identity was generated or deployed on BAHAA.
- **Observer:** guarded optional fresh `-NewHostOnly` provisioning accepts the
  approved guest/profile, a PSCredential and bounded UTC expiry. Fixed SQL uses a
  locally generated SCRAM verifier, never a plaintext observer password. The
  NOBYPASSRLS login can SELECT only two scoped views. Their separate NOLOGIN
  BYPASSRLS owner has bounded column grants and no memberships. Ordinary setup,
  table policy set, runtime/identity/migrator grants, historical migrations and
  Recovery Authority code remain unchanged. Ordered HBA rules restrict the login
  to the exact loopback database. Success retires bootstrap; failure disables both
  logins or explicitly requires disposal if retirement cannot be confirmed.
  Post-DDL failure can retain inaccessible objects for evidence; no silent repair.
- **Installed tests:** preparer checks the dedicated observer and actual fresh
  views before markers. P001/P006 use those views while retaining exact real-data/
  original-receipt assertions. The example admission JSON intentionally has false
  approval and invalid evidence placeholders. It cannot admit a fixture.

## Focused execution and evidence

The new `recovery-admission` scope runs only its engineering job on `windows-2025`
with normal Defender enabled. It compiles the actual locked Dart migration runner
(SDK 3.13.7), stages pinned PostgreSQL 16.16, tests pure identity/network/rollback
logic, Windows PowerShell 5.1 operator and real SYSTEM tasks under AllSigned, and
real production SQL initialization/permissions. No application/installer build or
unrelated GUI/Linux/full-CI run is part of this job.

Signing test keys/trust and policy changes exist only on the disposable hosted
runner and are fixture-only; they do not supply a release publisher. SQL tests use
temporary clusters, random secrets and an independent CI seed administrator,
never installed service-secret extraction. A physical copy starts a **fresh
second cluster** on another port, preserving the original; it is not P006.

Hosted execution commands, after workflow migration compilation/PG staging:

```powershell
& .\scripts\ci\test-recovery-lab-admission.ps1
& .\scripts\ci\test-recovery-script-signing.ps1
& .\scripts\ci\test-recovery-lab-observer.ps1
& .\scripts\windows\test-host-new-install-state.ps1
& .\scripts\windows\test-unified-installer-path-contract.ps1
```

Do not run hosted fixture scripts on BAHAA or the owner VM. Use the workflow.
Exact revisions, actual cases and retained evidence are recorded below after
execution. Prepared is not Passed.

## Minimum owner actions before physical admission

1. Approve guest-only rename/restart to `VENTIO-W2-VM01`; recheck all identity/SSH
   pins. Review printer servicing after that restart; never clear the rename queue.
2. Approve the exported exact adapter plan/rollback with console recovery available.
   Validate second-session SSH, DHCP and IPv4/IPv6 separation using disposable
   witnesses. Do not probe preserved systems.
3. Supply an approved signing identity through the protected GitHub
   `wave2-script-signing` environment: PFX/password secrets, publisher thumbprint,
   timestamp service and environment approvals (or a separately reviewed signing
   service). No private key on BAHAA/guest. Approve guest-only public chain/publisher
   trust and normal AllSigned policy; verify operator/SYSTEM effective scopes
   without weakening application control.
4. Review one replacement signed candidate, complete hashes, signatures and enabled
   protection evidence. Do not patch the previous unsigned 0.1.23+24 ZIP in place.
   Separately approve VM-only installation and the privileged observer profile.
5. Complete real business identity/package/scope setup and verify fresh observer,
   services and independent witness. Approve an admission record with actual
   network/signing evidence hashes. Use the updated installed preflight. Local
   operations/destructive P001–P006 require **later separate** authorization.

Real release signing, vNIC enforcement, physical operator/SYSTEM policy,
installation, business fixtures, genuine marker creation, P001–P006 and manual
M001–M006 remain unexecuted/blocked. The separate elevated-token PostgreSQL
single-user recovery defect remains open; these tests do not close it.
