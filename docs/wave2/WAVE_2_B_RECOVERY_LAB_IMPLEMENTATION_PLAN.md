# Wave 2 B recovery-lab admission implementation plan

Date: 2026-11-19. Reviewed source: `feature/wave-2-a` /
`bd9b8418767aff0d887aa5b8247676f1703ad588`.

**Verdict: BLOCKED for installation and P001–P006; source engineering is authorized.**
This document prepares the solution and approval boundaries. The proposed code,
signing pipeline and infrastructure changes below are not implemented or tested by
this plan. Existing admission guards remain enabled. No installation, policy or
network change, SYSTEM task, recovery operation or destructive test was performed.
PR #6 remains Draft and unmerged; Wave_2_C remains closed.

## Verified baseline and evidence limits

- The owner designates **only Ventio-Recovery-Lab** disposable. BAHAA contains
  important data and is a management/courier host, never a disposable execution,
  build, signing or recovery-test target. A healthy guest does not establish
  hypervisor trust; a hypervisor administrator can control its guests. Recovery
  results on this host must retain that assurance limitation.
- Read-only SSH on 2026-11-19 at 17:00 UTC succeeded with the existing `ventio_lab`
  key, pinned ED25519, strict checking, no agent forwarding and no host-key update.
  Guest Windows hostname is `DESKTOP-CJVPE84`, not its Hyper-V display name.
- Guest Windows 11 Pro 26H2 is build `26300.9974`. Earlier readings at 16:13–16:16
  UTC recorded KB5132061, Defender `1.463.368.0`, enabled normal real-time/tamper/
  archive/script protection, no exclusions and no threats/detection history. Full
  scan ended `2026-11-19T14:35:29.497Z`. These are dated observations, not enduring
  clearance. Refresh them before admission; repeat neither an installed update nor
  an already completed scan without a reason.
- CBS/Windows Update/Defender reported no reboot requirement. Ten pending printer
  driver rename pairs remain a servicing warning. Review normal servicing and, if
  necessary, authorize a guest restart and recheck; never clear the registry queue.
- Default Switch connectivity, outbound-Allow guest firewall profiles and no
  returned vNIC ACLs do **not** demonstrate network isolation. No TEST-01/02 or
  production endpoint was probed. PowerShell is still `Restricted`; inspected
  setup/operator/test scripts are unsigned. SYSTEM execution compatibility has not
  been exercised. Smart App Control evaluation was observed; it is not disabled.
- No installed Ventio services, data or real fixture marker were observed. Existing
  results remain **158 recorded case passes, six P cases blocked**, plus six
  separate manual/device cases. This plan adds no passes or new candidate.

The dated JSON observations and their SHA-256 index are retained in
[admission evidence](evidence/20261119-recovery-admission/README.md).

## Ordered work and ownership

“Independent” means source edits/review and narrowly scoped GitHub-hosted tests,
with no product execution on BAHAA. “Owner approval” below is required before an
engineer applies the specified environment change; it does not imply the owner
must manually perform every command.

| Priority | Established problem / cause | Secure implementation | Independent work | Owner action or approval | Evidence that closes the item |
|---|---|---|---|---|---|
| 1 — identity | Runbook excludes BAHAA as hypervisor; both scripts require `VENTIO-W2-VMxx`, while the genuine guest is `DESKTOP-CJVPE84`. A display name is insufficient. | Scope eligibility to the exact disposable guest; retain hostname/elevation/marker guards and add exact VM/OS identity binding. | Shared read-only identity validator, fail-closed input schema, negative tests and source review. | Authorize a normal **guest-only** rename to `VENTIO-W2-VM01` and restart before provisioning. No BAHAA rename or exemption. | Matching host/guest identity evidence after restart, same SSH fingerprint, rejection of preserved/wrong/physical identities. |
| 2 — isolation | Current Default Switch allows routed/NAT egress; guest outbound is Allow. | Per-VM vNIC stateful SSH allow plus default-deny new traffic in both IP families, with only required DHCP control traffic. No general Internet/DNS/LAN egress during P tests. | Generate/review exact rule and rollback plans; validate address families, priorities, adapter scope and permitted flows in source/CI. | Authorize applying the reviewed rules to **this VM's adapter only**, using an elevated management console and keeping Hyper-V console recovery available. Approve any additional required flow explicitly; deny-all enforcement does not depend on a complete production-IP inventory. | Before/after rule exports, a second pinned SSH session, effective deny results against disposable witnesses; no contact with TEST-01/02. |
| 3 — execution | `Restricted` blocks script files even if signed; operator, broker and SYSTEM scheduler all depend on files/modules. | Trusted signed payload/test scripts and a normal guest machine policy of `AllSigned`, with publisher trust available to operator and SYSTEM. No process override or alternative interpreter path. | Signing/inventory changes and positive/negative operator/SYSTEM probes on disposable GitHub runners. | Select an acceptable signing identity; approve **guest-only** certificate trust and AllSigned configuration. A stronger enforced enterprise/application policy is not overridden. | Valid expected publisher/chain on every executed script/module, effective policy from both contexts, successful signed harmless probes; unsigned/tampered/untrusted probes denied. |
| 4 — observer | Normal setup generates private credentials, initializes SQL, then retires bootstrap. It offers no observer path. A DSN cannot be provisioned afterward with ordinary runtime authority. | Explicit, fresh-disposable-fixture-only bootstrap profile exposing bounded read-only observer views; preserve the ordinary SQL policy set and runtime grants. See design below. | Implement/review the fixed profile, provisioning boundary, P query changes and real PostgreSQL integration tests. | Explicitly approve the bounded privileged fixture observer profile when approving fresh VM setup. No production credentials or service-secret extraction. | Authorized view reads work, raw/base-table/cross-scope reads and writes fail, production RLS/profile checks still pass, bootstrap login retired, normal setup creates no observer. |
| 5 — fixture | No installed Host/PostgreSQL, scope/package/operator, observer or genuine fixture marker exists. | One newly reviewed CI candidate; supported fresh Host setup, genuine Recovery Authority, exact scope/package/grants; then installed preflight and private identity-bound markers. | Prepare scripts, prerequisite checks, evidence schema and targeted CI rehearsal; rebuild once after payload changes settle. | Separate **VM-only installation and fixture-provisioning approval** after items 1–4 pass. P001–P006 require later explicit local-operation/restore approval. | Exact installed file hashes, real service identities, current authenticated scope, bounded observer, external protected witness and fresh backup root; admission passes without running P cases. |

## Identity and host eligibility design

Record these independent identifiers rather than equating them:

| Field | Approved target / observation |
|---|---|
| Hyper-V management host | `BAHAA` — preserved, not disposable |
| BAHAA Windows MachineGuid (deny as execution target) | `206b0dfe-e035-49c5-8b38-3d1d19ceadf7` |
| Hyper-V VM display name / VMId | `Ventio-Recovery-Lab` / `99aba626-2cc9-486e-86ab-af7966848126` |
| Guest MachineGuid | `5cb98737-7141-4486-9a87-08484566e292` |
| Guest SMBIOS UUID | `BBFBFFD7-D087-4E7C-9D65-D7884CAE0420` — **different from VMId** |
| Guest hardware / generation | Microsoft Corporation / Virtual Machine; Hyper-V generation 2 |
| Guest hostname now / required after approved rename | `DESKTOP-CJVPE84` / `VENTIO-W2-VM01` |
| vNIC MAC / current switch | `00155D016805` / `Default Switch` |
| SSH ED25519 fingerprint | `SHA256:2apYDxmYxd9YL51EUuqWJRKYAF6grFa/pE1wbds7b0I` |

Add a shared identity check used by both
`tests/wave2/prepare_installed_vm_fixture.ps1` and
`tests/wave2/windows_operations_acceptance.ps1`. Keep the existing hostname regex,
normal administrator elevation, explicit opt-in, private marker ACLs, MachineGuid,
candidate hashes, exact tenant and both destructive-operation switches. Add the
SMBIOS UUID and an independently reviewed admission-record digest to markers and
verify both again before any P-case mutation. Reject missing/unknown/changed
identity, preserved machine names/GUID and physical hardware. A record copied to
another guest must fail. Do not create a valid fixture marker before installation.

The management-side checker must select Hyper-V by **VMId**, verify name/MAC and
adapter count, and compare with a pinned SSH guest observation. Reconnect/IP
changes require re-verification, not automatic repinning. Guest-only checks cannot
authenticate a Hyper-V management identity; retain the independent management
observation and owner approval rather than pretending a guest-supplied VMId proves
it. Do not add a `SkipAdmission`, generic hostname exception or `Force` option.

## Isolation design and rollback boundary

P001–P006 use loopback HTTP `127.0.0.1:8080`, SQL `127.0.0.1:54329`, local services,
files and Task Scheduler. They need no connection to a physical Ventio Host,
production database or Internet service. Transfer approved artifact/data through
the existing SSH channel; verify against independently recorded CI digests.

Prepare an **adapter-scoped** Hyper-V extended-ACL change set, selected by VMId
and exact adapter MAC, not `-ManagementOS` or an all-VM/switch-wide operation.
First confirm feature support on this Windows client/switch combination; the
documented API is not evidence that the current switch enforces it correctly.
Permit inbound TCP/22 only from the verified BAHAA virtual-switch management IP
(currently `172.19.240.1`), with stateful return traffic. Explicitly account for DHCP
broadcast/renewal and responses. Deny other new inbound/outbound traffic over both
IPv4 and IPv6, including new guest-initiated connections to BAHAA. Do not replace
this with “allow all RFC1918,” unrestricted HTTPS or a blocklist of two current IPs.
Keep existing guest firewall protections enabled; any complementary guest rules
also require approval. Host-service firewall openings must not defeat vNIC denial.

Capture existing rules and exact proposed additions before applying. Keep the VM
console open; add/verify the management allowance before final deny rules, then
verify a second SSH session. Rollback removes only this change set/restores this
adapter's recorded prior rules. Never alter BAHAA's general firewall, Default
Switch/NAT, other adapters, user data or other VMs. If this control cannot be
enforced on the existing switch, stop and propose an owner-approved isolated lab
network/host; do not silently reconnect or weaken the guard.

Acceptance requires effective IPv4/IPv6 tests using disposable allowed/denied
witness endpoints under approved test control, plus rule/counter evidence.
Protected physical endpoints are not test witnesses. Refresh updates/definitions
before the isolated window, or use separately approved signed offline updates;
do not leave broad update egress open throughout recovery testing. Isolation here
protects against guest-originated traffic, not a malicious hypervisor administrator.

## PowerShell and build design

The installer, setup broker and scheduled task must continue using ordinary
`powershell.exe -NoProfile -NonInteractive -File ...`, without ExecutionPolicy
arguments. Neither stdin/encoded script execution, alternate hosts, zone removal,
`Unrestricted` nor application-control disablement is an acceptable compatibility
fix. AllSigned is the proposed normal policy, not an exemption from stronger policy.

Inventory the complete executable script closure: payload setup/operator/backup/
restore `.ps1` and `.psm1`, any loaded script configuration, fixture tooling and its
modules. Sign staged **output copies on a clean runner**, before generating payload
and package SHA-256 manifests and before the installer embeds them. Preserve the
clean unsigned Git source archive; record original-source hashes, distributed
signed hashes, exact certificate/publisher/chain and timestamp evidence. Verify
signatures and all final manifests again after packaging. Never rewrite an approved
ZIP in place or install a partially signed payload.

The signing private key must not reside on BAHAA or the guest; use an approved
protected signing service/CI secret boundary with a pinned identity. No such
signing identity is currently supplied. A lab-only test certificate may prove CI
behavior but cannot establish release publisher trust. The guest needs the approved
public chain/publisher in machine stores usable by SYSTEM; record exact additions
for rollback. This requires explicit security-configuration approval.

On a disposable hosted runner, exercise valid/unsigned/tampered/untrusted signed
script and module cases under AllSigned, then repeat harmless probes through an
actual SYSTEM task. Capture identity, effective policy **and all scopes**, exit code
and signatures. Do not count an operator-only policy probe or an unsigned script
run under the hosted image's normal policy as proof. No P cases or destructive
operations belong in these compatibility probes. Leave application control enabled;
an actual block is evidence to investigate, not permission to bypass it.

## Supported disposable SQL observer design

Source review establishes two constraints: `initialize-host-database.ps1` retires
`ventio_bootstrap` before returning, and `security/postgres/runtime_check.sql`
rejects additional RLS policies on the protected tables. `test_logins.sql` is for
`ventio_host_test`, not this installed `ventio_host`. Do not use those test logins,
reuse a runtime credential, add an ad-hoc RLS policy or recover a service secret.

Implement a fixed, explicitly selected **fresh disposable fixture** provisioning
profile in `provision-host-installation.ps1` / `initialize-host-database.ps1`,
admitted by the reviewed identity record and fresh `-NewHostOnly` path. Default
normal setup remains unchanged and creates no observer. Refuse retained clusters,
partial recovery, upgrade, preserved machines, missing identity, existing fixture
roles/objects or an arbitrary SQL/script callback. Do not alter historical
migrations, the normal schema manifest or Recovery Authority implementation.

During the legitimate initial bootstrap window, in a bounded SQL transaction
before bootstrap retirement:

1. Create a dedicated **NOLOGIN, NOSUPERUSER, BYPASSRLS** view owner with no members,
   role creation, database creation or replication rights. Grant only the columns
   needed from `ventio_records` and `ventio_command_journal`. This is an explicit
   **privileged fixture read surface**, not a least-privilege application role or
   an assertion that no privilege was added. It needs owner approval for this
   disposable cluster only; no ordinary login can inherit or SET ROLE to it.
2. Own two fixed `security_barrier` views under a private fixture schema. Hardcode
   tenant/company/branch to `w2-physical-disposable` / `w2-company` / `w2-branch`.
   The record view exposes only the `W2-BACKUP-SENTINEL`, module `com.example.wave2`,
   DocType `Asset`, and the observed value. The receipt view exposes only
   `command_id` and `receipt->>'status'` in the fixed fixture scope; P006 compares
   the exact random command ID returned by P001. The actual journal has no
   aggregate/module column, and CommandReceipt carries no aggregate ID: do not
   invent that predicate or expose whole receipts.
3. Give a separate short-lived SCRAM LOGIN **NOBYPASSRLS**, no role memberships and
   only CONNECT, fixture-schema USAGE and SELECT on those two views. No table,
   sequence, write, DDL, role-management or private recovery-schema access. A fixed
   observer-specific pg_hba allow/reject section, ahead of generic rules, must
   constrain this login to this database over `127.0.0.1` with SCRAM; otherwise
   PUBLIC CONNECT defaults could permit connections to other databases. Include
   that supported fixture-only configuration in installation approval. Set
   read-only/session time limits as additional controls, not substitutes for ACLs.
   Fresh observer secrets are supplied as PSCredential and retained only for this
   fixture session; no passwords in argv, manifests, source or evidence.
4. Verify grants, fixed definitions and login behavior; then retire bootstrap
   normally (`NOLOGIN PASSWORD NULL`) and prove a new bootstrap login fails.
   Do not leave an authenticated bootstrap connection available after setup.

Profile failure must prevent Host startup and fixture-marker creation, roll back
partial observer objects, and retire the temporary bootstrap authority before
returning. If retirement cannot be confirmed, keep the fresh lab isolated and
require disposal/recreation, never fall back to recovery, trust authentication or
a retained bootstrap credential.

This design keeps table RLS policies/FORCE RLS and all runtime/identity/migrator
grants unchanged; privileged reads occur only behind the fixed views. PostgreSQL
checks view-owner permissions by default, so **the defining role, view predicates,
absence of memberships and denied base-table access require real negative tests**.
Do not ship this profile until those checks and ordinary security-profile checks
pass. The privileged observer is never part of normal production setup.

Change P-suite observer reads to those views without reducing the actual
before-backup/restored-value and original-receipt assertions. Granting SELECT alone
does not solve current FORCE RLS. Observer credentials/objects must survive the
real physical backup and restore; expiry must cover the authorized run window.
Prove that with a disposable PostgreSQL integration fixture before VM admission.

## Targeted implementation and validation sequence

| Source change set | Focused tests / expected evidence | Execution boundary |
|---|---|---|
| Shared identity validator + both P-suite entry points | Correct pins accepted; wrong name/GUID/SMBIOS/marker/ACL, BAHAA, TEST names and copied fixture rejected **before side effects**. Retain both explicit destructive switches. | New source tests on GitHub-hosted Windows; no forged “admitted runner” and no P execution. |
| Network plan generator / inspector | Correct single-adapter target; stateful SSH and required control flows; IPv4/IPv6 deny coverage, no broad allows, exact rollback set; export-only mode causes no configuration mutation. | Pure plan tests in CI. Actual enforcement/connection preservation only after owner-authorized infrastructure preparation. |
| Signing stage and policy compatibility probes | Sign-before-hash ordering, complete script closure, strict publisher checks; valid and negative operator + real SYSTEM results; preserve installer no-override assertions. | Disposable GitHub-hosted Windows only; fixture certificates explicitly labelled non-release. |
| Disposable observer profile + P view queries | Real PG 16.16 positive/cross-scope/base-table/write/SET ROLE/role-expiry tests; unchanged runtime policy checks, ordinary setup observer absence, rollback on failed profile and bootstrap retirement. Copy to a **fresh second** cluster directory/port to verify observer persistence; never replace the original. | Narrow Windows/PostgreSQL regression job; no installed Ventio or destructive P cases, physical test hosts or production data. |
| Final fixture tooling and documentation | Static script/JSON validation, all original 161 case IDs preserved (164 with S021–S023), separate production/test/signing revisions and clear prerequisites. | Static review locally; executable checks on clean CI. P001–P006 remain unexecuted until approved installed fixture. |

Use a new narrowly scoped recovery-admission workflow input/job rather than
`scope=all`. Do not dispatch unrelated GUI/Linux/full acceptance jobs. Implement
and validate the source sets first; build **one** replacement unified candidate
after signed payload bytes and provisioning changes settle. Record exact commit,
source tree, dependencies/toolchains, artifact ID, ZIP/member hashes, signatures
and enabled-protection scan evidence. The previous candidate
`Ventio-W2B-0.1.23+24-20261118-50d4d2bb4189-gh44267441630-a1` is reference evidence,
not the signed/profile-capable candidate proposed here. No new artifact is claimed.

The separately recorded elevated-token `postgres --single` credential-recovery
failure remains open. Do not use it to provision the observer. The current P suite
does not directly call that path, so its eventual pass would not close that defect.

## Final admission, authorization and recovery sequence

1. Complete independent source/targeted-CI work; review evidence. Obtain approval
   for the exact VM-only rename/restart, adapter change set and signing/policy
   configuration. These changes have **not** been approved or applied by this plan.
2. Apply only approved preparation; verify pins, isolation, protection/current
   servicing and operator/SYSTEM compatibility. Stop on changed identity or policy.
3. Obtain separate VM-only installation/profile-provisioning approval for the new
   exact candidate. Verify transferred ZIP and every member, scan ZIP/extracted
   payload with enabled protection, then install through normal UAC. No SDK,
   separate PostgreSQL install or production inputs are required.
4. Complete supported Host setup, real service identities, independent service-
   created Recovery Authority, the exact tenant/company/branch and approved
   `com.example.wave2` 1.0.0 package. Provision current operator workspace/operations,
   package review and Asset CRUD/field authority. Validate the bounded observer.
   Keep credentials out of transcripts and clear temporary fixture secrets after
   use. BAHAA receives no signing key or production credential.
5. Run the non-mutating installed preflight, review output, then create genuine
   private VM/source/network/publisher-bound fixture records. Record candidate
   production commit separately from the reviewed test/provisioning commit.
6. Only after explicit local-operation **and destructive restore** authorization,
   execute P001→P006 once on that fresh fixture: authentication/sentinel; real SYSTEM
   policy; scheduled backup/deduplication; retention/pins; corruption rejection;
   physical restore with original receipt and independent witness preservation.
   Preserve logs, hashes, task invocation/result, service states, backup manifests
   and receipts, but no secrets. Mark later cases UNEXECUTED after fail-fast failure.
7. P006 leaves Host stopped for Recovery Authority reconciliation. Do not restart
   it, adopt an older witness, extract credentials or repeat on the mutated fixture.
   Preserve evidence and dispose/recreate **only the approved VM** for a fresh run.
   Snapshot reset is laboratory reset, never a production Recovery Authority repair.

All six P cases remain **BLOCKED_PREREQUISITE / UNEXECUTED**. Manual/device
M001–M006 and owner acceptance remain separate. No proposed test is marked Passed.

## Validation of this planning delivery

Changes are documentation and read-only evidence on `feature/wave-2-a`; production
and prepared test source files are unchanged. Four JSON observations parse, all
four evidence digests are recorded, the three original captures match their local
source bytes, and 11 local documentation links resolve. Tracked whitespace checks
are clean. The existing ED25519 known-host pin matches the owner's exact value;
strict SSH authentication and the management peer were verified read-only.
GitHub metadata confirms PR #6 is still open, Draft and unmerged at `bd9b841`.
No commit, push, workflow dispatch, build or test execution was performed for this
planning delivery. The implementation and targeted checks above remain planned.

## Source contracts and external references

- [Installed fixture runbook](WAVE_2_B_DISPOSABLE_VM_RUNBOOK.md),
  [fixture preparer](../../tests/wave2/prepare_installed_vm_fixture.ps1),
  [real installed P suite](../../tests/wave2/windows_operations_acceptance.ps1).
- [Host provisioning](../../scripts/windows/provision-host-installation.ps1),
  [database initialization](../../scripts/windows/initialize-host-database.ps1),
  [runtime profile checks](../../security/postgres/runtime_check.sql),
  [SQL bootstrap](../../security/postgres/bootstrap.sql),
  [payload builder](../../scripts/windows/build-host-payload.ps1).
- Microsoft: [stateful adapter-scoped Hyper-V ACLs](https://learn.microsoft.com/en-us/powershell/module/hyper-v/add-vmnetworkadapterextendedacl?view=windowsserver2025-ps),
  [PowerShell execution policy](https://learn.microsoft.com/en-us/powershell/module/microsoft.powershell.core/about/about_execution_policies?view=powershell-5.1),
  [script signing](https://learn.microsoft.com/en-us/powershell/module/microsoft.powershell.core/about/about_signing?view=powershell-5.1).
- PostgreSQL 16: [view-owner security](https://www.postgresql.org/docs/16/sql-createview.html),
  [row security and BYPASSRLS](https://www.postgresql.org/docs/16/ddl-rowsecurity.html).
