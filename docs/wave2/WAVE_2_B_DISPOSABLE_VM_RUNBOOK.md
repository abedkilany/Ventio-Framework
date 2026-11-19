# P001–P006 installed Windows fixture preparation

Status: PREPARED, NOT PROVISIONED OR EXECUTED. On 2026-11-19 the owner provided
Ventio-Recovery-Lab and designated only that VM disposable; BAHAA is preserved.
P001–P006 remain BLOCKED_PREREQUISITE. The consolidated
[recovery-lab implementation plan](WAVE_2_B_RECOVERY_LAB_IMPLEMENTATION_PLAN.md)
records current identity, isolation, policy and observer blockers, source work and
required owner approvals. No admission guard is waived by this documentation update.

## Provision a separate VM

Use a genuinely disposable Windows 11 x64 VM named `VENTIO-W2-VM01` (4 vCPU,
8 GiB RAM and at least 80 GiB disposable NTFS storage are practical starting
allocations). The owner's designated guest on BAHAA may be prepared under the
exact VM/OS/SSH identity and isolation conditions in the consolidated plan.
BAHAA itself remains ineligible for installation, product execution, signing,
builds or recovery tests. Its management role does not establish hypervisor trust;
retain that assurance limitation. Both physical test computers remain out of scope.
The guest currently reports `DESKTOP-CJVPE84`, which fails the preserved hostname
guard. A normal guest-only rename/restart requires separate owner approval, with
VMId, MachineGuid, SMBIOS UUID and SSH pin rechecked afterward. Do not widen the
guard or rename TEST-01/02, BAHAA or a hosted runner to satisfy it.
Isolate it from both physical test computers and their PostgreSQL/Host endpoints.
No physical credentials, data, certificates, Recovery Authority, backups or Client
profiles are copied. The VM and all its data must be explicitly disposable.

Apply Windows updates, complete any restart, and verify Defender/current signatures,
real-time and archive scanning with no exclusions or active threat. This runbook
does not disable protections, change script policy, remove zone markers or bypass
application control. Stop if normal policy blocks setup or a prerequisite.

Before provisioning, record the approved candidate identity, source commit, exact
inner ZIP SHA-256, complete member manifest, source/toolchain metadata and protected
scan report. Use the newly corrected candidate after its CI/security review, not
the earlier BAHAA artifact or a superseded candidate. Verify the complete ZIP and
extracted members; scan both locally under enabled protection. Install through
normal UAC and stop if Windows blocks it. Complete supported Host setup in this
VM only, selecting tenant `w2-physical-disposable`, company `w2-company` and branch
`w2-branch`. Preserve the actual service-created independent Recovery Authority.
The hostname restriction belongs to a genuinely new VM; it is not an authorization
to run destructive tests on an existing machine.

## Supported identity and observer prerequisites

Use normal first-administrator bootstrap/pairing and grant the test operator current
exact-scope authority: workspace and operations management, package submission/read/
review, and create/read/update/delete/field grants for the declarative test Asset.
Install/approve the bounded `com.example.wave2` package described by
`packages/ventio_core/test/support/wave2_fixtures.dart`, through supported package
submission and review. The installed suite uses genuine authenticated HTTP and the
real local operator, Task Scheduler and PostgreSQL services. It does not substitute
a fixture observer for an application request.

Supply a dedicated disposable observer DSN for `127.0.0.1:54329/ventio_host`, with
access to read the seeded record and command receipt. Arrange this explicitly while
creating the isolated fixture; do not extract an installed service DPAPI credential,
reactivate the retired bootstrap login, reset a witness or relax RLS to acquire it.
The current normal initializer has no supported observer provisioning option;
the scoped bootstrap/view profile in the implementation plan is proposed source
work, not an existing command or completed fixture. Do not improvise SQL after
bootstrap retirement or use `ventio_host_test` login fixtures on this database.
If a supported fixture administration path cannot provide the observer, stop and
record that prerequisite as BLOCKED. A privileged observer, if separately approved
for the disposable cluster, is test infrastructure only and never an application
connection. The production runtime/identity roles remain least-privilege.

Provide the legitimate fixture token and observer DSN via process environment
(`VENTIO_W2_TOKEN`, `VENTIO_W2_OBSERVER_DSN`). Do not put secrets in manifests,
command lines, Git, screenshots or chat. The fixture preparation script reads the
current session, not the protected credential store. No old token is adopted after
restore. Set `VENTIO_WAVE2_PREPARED_TESTS=yes` only in the dedicated VM session.

## Admit the installed fixture without executing tests

From the exact reviewed test checkout, in a normally elevated Windows PowerShell
session, run the following with the actual independent expected values:

Record the test-source commit separately from the candidate's production-source
commit. Later fixture-only corrections do not rebuild or change candidate bytes.
ExpectedCommit below refers to the installed payload's independently verified
production-source commit, not a different test/report checkout.

```powershell
& .\tests\wave2\prepare_installed_vm_fixture.ps1 `
  -CandidateZip 'C:\Acceptance\APPROVED-CANDIDATE.zip' `
  -ExpectedZipSha256 'APPROVED_64_LOWERCASE_HEX' `
  -ExpectedCommit 'APPROVED_40_LOWERCASE_HEX' `
  -ExpectedPayloadManifestSha256 'APPROVED_64_LOWERCASE_HEX'
```

The placeholders intentionally fail argument validation. The script first verifies
the VM name, normal elevation, current protection/restart status, complete installed
Host member hashes, service identities/paths, external witness owner/protection,
fresh backup root, loopback observer endpoint and current authenticated operations
grant. It does not run an installer, execute a test case, mutate SQL, stop a service,
change policy, reset Recovery Authority or extract a credential. Review and preserve
the preflight result. Then repeat with `-CreateFixtureMarker` to create two new
administrator-owned private fixture records under `%ProgramData%\Ventio-W2-Disposable`.
It refuses existing marker directories and binds the records to the actual Windows
MachineGuid, source commit, package hashes and real session actor/device. A marker
is fixture admission metadata, not malware clearance or authorization by itself.

No admission script invocation occurred in this engineering session. This new
preparer still requires rehearsal on the new VM; static parsing alone is not a pass.

## Later explicit destructive execution

After fixture review and explicit local-operation/restore authorization, use normal
elevation and the same reviewed candidate/test revision:

```powershell
& .\tests\wave2\windows_operations_acceptance.ps1 `
  -FixtureManifest "$env:ProgramData\Ventio-W2-Disposable\installed-fixture.json" `
  -ApproveLocalOperations -AllowDisposableRestore
```

P001 authenticates/seeds a real record; P002 arms the actual SYSTEM schedule through
supported local approval; P003 verifies the real scheduled copy/daily deduplication;
P004 exercises actual retention and pinned/foreign-kind protection; P005 verifies
corruption rejection before Host stop; P006 restores a verified cluster, preserves
the current cluster/external witness/original receipt and leaves Host stopped for
Recovery Authority reconciliation. These are six automated cases with real installed
prerequisites, not six manual GUI passes.

Retain stdout, exit code, operation IDs/journals, task state, original/retained backup
manifests and full integrity results, pre/post service state and independent witness
hashes. Never log credentials or record protected values. Record fail-fast later
cases as UNEXECUTED. After P006 do not automatically restart Host, adopt an older
witness, resurrect credentials or repeat the suite on its mutated fixture. Preserve
evidence and dispose/recreate the entire VM for another run. VM snapshots are only
for disposable-environment reset, not a supported production Recovery Authority
rollback. M001–M006 owner/device acceptance remains separate.

The prepared scheduler assertions wait for a new LastRunTime, Ready state and
successful LastTaskResult after each explicit invocation, rather than accepting
the old Ready state immediately after queueing a task. This prevents a scheduling
race from masquerading as a deduplication pass. This fixture correction has been
parsed and reviewed only; it remains unexecuted with P001–P006.
