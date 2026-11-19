# Recovery-lab engineering implementation — 2026-11-19

Scope: `feature/wave-2-a`, PR #6 Draft/unmerged; Wave_2_C closed. Source work and
targeted GitHub-hosted execution only. No owner VM/BAHAA configuration changed,
no TEST-01/02 access, Ventio installation or P001–P006 execution occurred. The
[initial plan](WAVE_2_B_RECOVERY_LAB_IMPLEMENTATION_PLAN.md) and read-only
observations are retained; this report supersedes its planning-only status.

**Targeted engineering: 74 auxiliary cases PASSED, zero remaining failures in the
validated suites. Physical admission: BLOCKED / NOT EXECUTED.** Engineering source
is `7260b02f43898734c7e986103a5f8dbe82bea8e5`, tree
`89ce498cc002cc4ce2187d5492bd544c81244f03`. A later evidence/documentation commit
does not change those tested source files. The case-level
[results matrix](WAVE_2_B_RECOVERY_LAB_RESULTS.json) records each case, capability
mapping, exact run/revision, artifact ID and independently verified ZIP digest.

| Validated suite | Passed / failed | Provenance |
|---|---|---|
| Identity, plan, rollback logic | 29 / 0 | [44587707476](https://github.com/abedkilany/Ventio-Framework/actions/runs/44587707476), 2ae0188; relevant files byte-identical at the final engineering source. That historical run's SQL failure was subsequently corrected. |
| Script/signature negatives, operator and real SYSTEM | 18 / 0 | [44593187246](https://github.com/abedkilany/Ventio-Framework/actions/runs/44593187246), 7260b02, using the shared read-only policy probe. |
| Real PG initialization, observer permissions, failure/recovery boundaries | 27 / 0 | [44592150075](https://github.com/abedkilany/Ventio-Framework/actions/runs/44592150075), 3d83958; relevant files byte-identical at the final engineering source. |
| Existing new-install and installer-path contract programs | Both passed | 44592150075; these are two regression programs, not additional P passes. |

No new package was built. Real release signing/timestamp integration requires an
owner-selected signing identity; the CI test identities are not release identities.
Full signed Host-payload/installer integration therefore remains unexecuted. The
builder's strict mode (`-RequireSignedScripts` plus the approved certificate and
timestamp parameters) must be used for the next acceptance candidate.

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
  `tests/wave2/recovery_policy_probe.ps1` supplies the harmless operator/SYSTEM
  metadata probe used by the signing suite. Its signed output copy can later be
  used in the owner VM after policy/task approval; the hosted certificate-creation
  test itself must never run there.

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
& .\scripts\ci\run-recovery-observer-fixture.ps1 # pwsh; bounded Windows PowerShell 5.1 child
& .\scripts\windows\test-host-new-install-state.ps1
& .\scripts\windows\test-unified-installer-path-contract.ps1
```

Do not run hosted fixture scripts on BAHAA or the owner VM. Use the workflow.
Exact revisions and actual cases are recorded in the results matrix above. These
are engineering prerequisite checks; they do not count as physical product passes.

The identity/network scope can also run alone as `recovery-identity`; signing as
`recovery-signing`; SQL/provisioning as `recovery-observer`. Later SQL fixes used
only the latter, without repeating the passed signing/identity suites.

## Diagnostic findings and corrections

These runs exercised new source on disposable hosted runners; none changed an
installed owner environment. The strict checks were retained through correction.

| Finding | Correction / evidence boundary |
|---|---|
| Rollback order on hashtable rules | Explicit numeric sort expressions; the unchanged NET11 assertion now passes with the other 28 admission/network cases. |
| Windows PowerShell module autoload in a pwsh child | Supply only native Windows PowerShell module roots to that child and explicitly import its built-in Security module. No policy override. |
| Omitted observer expiry rejected ordinary setup | Explicit MinValue defaults in both entry points; the normal no-observer initialization is exercised against real PostgreSQL. |
| Diagnostic progress reader locked its writer | Atomic progress snapshots and shared read/delete access in the harness; no product assertions were changed. |
| HBA replacement changed security descriptors | Retain the original file object, acquire exclusive access, bound/decode the original content, perform a durable write and check the unchanged descriptor before reload. This is fresh-fixture bootstrap only: interrupted setup retires logins or requires disposal, never retained-cluster recovery. |
| Excessive installed preflight prerequisite | Verify receipt-view access without requiring an empty journal, which may contain legitimate business-setup receipts. P006 still compares the exact new P001 command UUID; the sentinel must be absent before seeding. This preparer remains physically unexecuted. |

The first two diagnostic runs were cancelled after a hanging fixture. Only run/job
metadata is available: GitHub returned zero artifacts and 404 BlobNotFound for
their logs. Their original stall cannot be fully reconstructed. Subsequent runs
use separate hidden server-control processes, bounded phases, incremental case
data and an artifact upload before SQL setup. Available evidence is retained;
missing logs are not represented as verified case results.

| Run | Source | Actual result |
|---|---|---|
| 44578358835 | a2bae1e | CANCELLED; identity/network step succeeded, signing step failed; raw case evidence unavailable. |
| 44581724169 | 5e10cb1 | CANCELLED; signing step succeeded, identity/network step failed; raw case evidence unavailable. |
| 44585530419 | 07e21f3 | FAILED: admission/network 28 passed, NET11 failed; signing 18 passed; SQL blocked at module loading. |
| 44587707476 | 2ae0188 | FAILED: admission/network 29 passed, signing 18 passed; SQL 19 passed then normal-setup guard failed, eight later cases unexecuted. |
| 44588573669 | b7e984f | FAILED: SQL progress-file sharing error before case execution. |
| 44589523473 | 4ff79a4 | FAILED: SQL 26 passed, OBS25 descriptor preservation failed. |
| 44590627091 | caaa3ef | FAILED: descriptor preservation guard stopped initial setup; SQL cases unexecuted. |
| 44592150075 | 3d83958 | PASSED: all 27 observer/security cases and both existing contract programs. |
| 44593187246 | 7260b02 | PASSED: all 18 signing cases with the reusable read-only probe; unrelated suites skipped. |

The auxiliary cases map to D09 (security/scoping), M05 (scheduled operations), M09
(recovery/integrity) and J03 (original receipts) as applicable. Network/identity/
signing cases are admission prerequisites, not replacements for product cases.
All 164 existing automated IDs across 22 capabilities, including the original 161,
are preserved. Earlier 158 product-case passes retain their original revisions;
they were not all rerun here. The six P and six manual cases remain separate.

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
   Provision secrets from a trusted administrative endpoint; do not paste private
   signing material into chat or Git.
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

Approved future network execution uses the exact downloaded `isolation-plan.json`
and its independently reviewed hash. Do not reserialize approved bytes. In an
authorized elevated BAHAA management session under its existing normal policy:

```powershell
# FUTURE APPROVAL ONLY; neither command was run on BAHAA.
& .\scripts\windows\prepare-recovery-lab-isolation.ps1 -Mode Apply `
  -PlanPath 'C:\Acceptance\isolation-plan.json' `
  -ExpectedPlanSha256 $approvedPlanSha256 -ApproveAdapterConfigurationChange
# Explicit rollback: removes only exact owned rules, retaining SSH until last.
& .\scripts\windows\prepare-recovery-lab-isolation.ps1 -Mode Rollback `
  -PlanPath 'C:\Acceptance\isolation-plan.json' `
  -ExpectedPlanSha256 $approvedPlanSha256 -ApproveAdapterConfigurationChange
```

BAHAA's current shell was observed with LocalMachine RemoteSigned and other scopes
Undefined. No policy or publisher trust was changed there. If its normal policy
later blocks a helper, stop; this is not authorization to bypass or alter it.
