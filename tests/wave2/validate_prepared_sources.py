"""Static source/matrix inventory only: never import or execute Dart/PS tests.

--write-matrix writes review documentation from literal source case declarations.
--analysis-snapshots copies source into the EXISTING native dependency context;
it changes no package metadata and invokes no resolver, analyzer or test runner.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import re
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
DOCS = ROOT / "docs/wave2"
CAPABILITIES = "A12 A11 K09 D08 J01 J03 K08 M01 M02 M05 M09 B09 C08 C09 C12 F05 H04 B02 K10 L01 D09 J04".split()
SUITES = {
    "C": ("core-contract", "packages/ventio_core/test/wave2_contracts_test.dart", "dart --packages=../ventio_native_client/.dart_tool/package_config.json test/wave2_contracts_test.dart"),
    "S": ("sqlite-component", "packages/ventio_native_client/test/wave2_workspace_store_test.dart", "flutter test --no-pub test/wave2_workspace_store_test.dart"),
    "H": ("postgres-http", "packages/ventio_host_api/test/wave2_gateway_integration.dart", "dart --packages=.dart_tool/package_config.json test/wave2_gateway_integration.dart"),
    "J": ("postgres-worker", "packages/ventio_host_api/test/wave2_jobs_integration.dart", "dart --packages=.dart_tool/package_config.json test/wave2_jobs_integration.dart"),
    "D": ("postgres-isolation-recovery", "packages/ventio_host_api/test/wave2_database_integration.dart", "dart --packages=.dart_tool/package_config.json test/wave2_database_integration.dart"),
    "O": ("postgres-operation-state", "packages/ventio_host_api/test/wave2_operations_integration.dart", "dart --packages=.dart_tool/package_config.json test/wave2_operations_integration.dart"),
    "U": ("postgres-upgrade", "packages/ventio_host_api/test/wave2_upgrade_integration.dart", "dart --packages=.dart_tool/package_config.json test/wave2_upgrade_integration.dart"),
    "R": ("existing-os-separated-audit", "packages/ventio_host_api/test/support/wave2_manifest_regression.dart", "dart --packages=.dart_tool/package_config.json test/engineering_audit.dart"),
    "E": ("sqlite-http-postgres", "packages/ventio_native_client/test/wave2_offline_integration.dart", "flutter test --no-pub test/wave2_offline_integration.dart"),
    "G": ("native-desktop-integration", "packages/ventio_native_client/integration_test/wave2_workspace_acceptance_test.dart", "flutter test --no-pub integration_test/wave2_workspace_acceptance_test.dart -d windows"),
    "W": ("windows-filesystem-component", "tests/wave2/windows_integrity_tests.ps1", "& ./tests/wave2/windows_integrity_tests.ps1 -PrivateFixtureParent $fixtureParent"),
    "P": ("disposable-installed-windows", "tests/wave2/windows_operations_acceptance.ps1", "& ./tests/wave2/windows_operations_acceptance.ps1 -FixtureManifest $fixtureManifest -ApproveLocalOperations -AllowDisposableRestore"),
}
CONTRACTS = {
    "A12": ["packages/ventio_core/lib/src/customization.dart", "security/postgres/wave2.sql", "security/postgres/wave2_customization_041.sql", "migrations/postgres/041_wave2_customization_validation.sql"],
    "A11": ["packages/ventio_core/lib/src/customization.dart", "packages/ventio_native_client/lib/src/workspace_page.dart"],
    "K09": ["packages/ventio_native_client/lib/src/workspace_store.dart", "security/postgres/wave2_customization_rebase.sql", "packages/ventio_native_client/lib/src/local_command_queue.dart"],
    "D08": ["packages/ventio_host_api/lib/src/wave2_platform.dart", "packages/ventio_host_api/lib/src/persistent_identity.dart"],
    "J01": ["packages/ventio_core/lib/src/data_transfer.dart", "packages/ventio_host_api/lib/src/wave2_platform.dart"],
    "J03": ["security/postgres/wave2.sql", "packages/ventio_native_client/lib/src/workspace_store.dart"],
    "K08": ["packages/ventio_host_api/lib/src/wave2_platform.dart", "packages/ventio_host_api/lib/src/persistent_identity.dart"],
    "M01": ["security/postgres/wave2_administration.sql", "packages/ventio_core/lib/src/platform_administration.dart"],
    "M02": ["security/postgres/wave2_administration.sql", "packages/ventio_core/lib/src/platform_administration.dart"],
    "M05": ["scripts/windows/manage-host-operations.ps1", "scripts/windows/HostBackupIntegrity.psm1", "security/postgres/wave2_operations.sql"],
    "M09": ["scripts/windows/restore-host-upgrade-backup.ps1", "scripts/windows/HostOperationStorage.psm1", "packages/ventio_host_api/lib/src/recovery_authority.dart", "security/postgres/wave2_operations.sql"],
    "B09": ["packages/ventio_core/lib/src/workspace.dart", "packages/ventio_native_client/lib/src/workspace_store.dart", "packages/ventio_native_client/lib/src/extension_store.dart"],
    "C08": ["packages/ventio_native_client/lib/src/workspace_page.dart", "packages/ventio_native_client/lib/src/extension_store.dart"],
    "C09": ["packages/ventio_native_client/lib/src/workspace_store.dart", "packages/ventio_core/lib/src/workspace.dart"],
    "C12": ["packages/ventio_native_client/lib/src/workspace_page.dart", "packages/ventio_core/lib/src/workspace.dart"],
    "F05": ["packages/ventio_host_api/lib/src/persistent_identity.dart", "packages/ventio_native_client/lib/src/workspace_page.dart"],
    "H04": ["security/postgres/wave2_activity.sql", "packages/ventio_host_api/lib/src/wave2_platform.dart", "packages/ventio_native_client/lib/src/document_activity_page.dart"],
    "B02": ["packages/ventio_host_api/lib/src/host_api.dart", "packages/ventio_core/lib/src/extension_commands.dart", "packages/ventio_postgres/lib/src/migration_runner.dart", "security/postgres/schema_profile.sql"],
    "K10": ["packages/ventio_core/lib/src/extension_commands.dart", "packages/ventio_host/lib/src/durable_command_host.dart"],
    "L01": ["packages/ventio_host_api/lib/src/wave2_platform.dart", "security/postgres/wave2.sql"],
    "D09": ["packages/ventio_host_api/lib/src/persistent_identity.dart", "packages/ventio_host_api/lib/src/recovery_authority.dart"],
    "J04": ["packages/ventio_host_api/lib/src/host_api.dart", "packages/ventio_host_api/lib/src/command_validation.dart"],
}
MANUAL = [
    ("W2-M001", "D09,C08", "Owner-visible first-admin bootstrap, independent local login/pairing, TLS fingerprint verification and OS credential-store behavior on the final installed candidate"),
    ("W2-M002", "K09,J03,C09,D08", "Two physical cleared devices, independent identities, real network disconnect/reboot/reconnect, conflict resolution and protected-field presentation"),
    ("W2-M003", "C08,C09,C12,F05,A11,A12,H04", "Windows keyboard/focus/high-DPI/narrow layout and Android tablet/320-400 px/rotation/accessibility acceptance; desktop size simulation is not Android acceptance"),
    ("W2-M004", "M05,M09", "Normal local UAC/approval UX, disk-full/copy/interruption/power-loss scenarios on disposable VM/storage, and review of uncertain physical operation journals"),
    ("W2-M005", "M09,D09", "Supported post-restore Recovery Authority reconciliation and fresh authentication without adopting a stale witness or resurrecting credentials"),
    ("W2-M006", "B02,C08", "Final installed Windows first-run, upgrade/uninstall, data-retention choices and cleanup in the same interactive session"),
]

PATTERNS = [
    re.compile(r"cases\.run\(\s*'(W2-[A-Z]\d+)'\s*,\s*'([^']+)'\s*,\s*'((?:\\.|[^'])*)'", re.S),
    re.compile(r"test(?:Widgets)?\(\s*'(W2-[A-Z]\d+) \[([^]]+)\] ((?:\\.|[^'])*)'", re.S),
    re.compile(r"Test-Case '(W2-[A-Z]\d+)' '([^']+)' '([^']*)'"),
]

def collect() -> list[dict]:
    cases = []
    for letter, (kind, filename, command) in SUITES.items():
        source = (ROOT / filename).read_text(encoding="utf-8-sig")
        found = []
        for pattern in PATTERNS:
            found.extend(pattern.finditer(source))
        if not found:
            raise ValueError(f"No literal case declarations in {filename}")
        for match in sorted(found, key=lambda item: item.start()):
            case_id, capabilities, requirement = match.groups()
            if not case_id.startswith(f"W2-{letter}"):
                raise ValueError(f"Suite mismatch: {case_id}")
            caps = capabilities.split(",")
            if set(caps) - set(CAPABILITIES):
                raise ValueError(f"Unknown capability in {case_id}")
            cases.append({"id": case_id, "capabilities": caps, "requirement": requirement,
                "source": filename, "line": source.count("\n", 0, match.start()) + 1,
                "suiteKind": kind, "command": command,
                "acceptanceReference": "docs/wave2/WAVE_2_B_VERIFICATION_PLAN.md#capability-acceptance-matrix",
                "productionContracts": sorted({p for cap in caps for p in CONTRACTS[cap]}),
                "status": "SOURCE_INVENTORY_ONLY"})
    ids = [case["id"] for case in cases]
    if len(ids) != len(set(ids)):
        raise ValueError("Duplicate executable case IDs")
    original = {f'W2-{letter}{number:03d}' for letter,count in
        dict(C=31,S=20,H=29,J=27,D=11,O=8,U=3,R=2,E=6,G=7,W=11,P=6).items()
        for number in range(1,count+1)}
    if len(original) != 161 or not original.issubset(ids):
        raise ValueError("An original prepared case ID was lost")
    if {cap for case in cases for cap in case["capabilities"]} != set(CAPABILITIES):
        raise ValueError("One of the 22 capabilities has no prepared source case")
    for case in cases:
        for path in case["productionContracts"]:
            if not (ROOT / path).is_file():
                raise ValueError(f"Missing inspected contract: {path}")
    return cases

def matrix(cases: list[dict]) -> dict:
    return {"status": "SOURCE_INVENTORY_ONLY", "baselineRevision": "87f8a5c388233f203920aaaec6acbc7bf544a6bc",
        "originalPreparedCaseCount": 161, "executionEvidence": "Recorded separately with exact CI run and revision; this static inventory executes no cases", "automatedCaseCount": len(cases),
        "cases": cases, "manualCases": [{"id": i, "capabilities": caps.split(","), "requirement": req,
            "status": "NOT_EXECUTED_OWNER_OR_DEVICE_REQUIRED"} for i, caps, req in MANUAL]}

def markdown(data: dict) -> str:
    lines = ["# Wave 2 B source case coverage", "", "**SOURCE INVENTORY ONLY. Execution outcomes are recorded separately with CI revision/run evidence.**", "",
        f"{data['automatedCaseCount']} executable source cases cover aspects of all 22 capabilities. This is a case inventory, not complete acceptance or a measured coverage percentage.", "",
        "Commands, fixture admission, reused coverage, physical requirements and remaining scenario gaps are in [the runbook](WAVE_2_B_TEST_PREPARATION.md).", "",
        "## Capability index", "", "| Capability | Prepared case IDs |", "|---|---|"]
    for cap in CAPABILITIES:
        lines.append(f"| {cap} | {', '.join(c['id'] for c in data['cases'] if cap in c['capabilities'])} |")
    lines += ["", "## Executable case-level matrix", "", "Every row below has status **SOURCE_INVENTORY_ONLY**. The original 161 case IDs are preserved; additional corrective cases are explicit. Fixture/command groups are defined in the runbooks. This table supplies no passed status.", "",
        "| Case | Capabilities | Requirement and assertion scope | Source |", "|---|---|---|---|"]
    for case in data["cases"]:
        requirement = case["requirement"].replace("|", "\\|")
        lines.append(f"| {case['id']} | {','.join(case['capabilities'])} | {requirement} | [{Path(case['source']).name}:{case['line']}](../../{case['source']}#L{case['line']}) |")
    lines += ["", "## Genuine owner/device acceptance", "", "| Case | Capabilities | Remaining acceptance |", "|---|---|---|"]
    for case in data["manualCases"]:
        lines.append(f"| {case['id']} | {','.join(case['capabilities'])} | {case['requirement']} |")
    lines += ["", "The JSON companion lists every case's production contract paths and exact invocation. Static inventory validation does not import a test library or execute any case.", ""]
    return "\n".join(lines)

def analysis_snapshots(clean: bool = False) -> None:
    target = ROOT / "packages/ventio_native_client/wave2_static_review"
    marker = target / "origins.json"
    if clean:
        entries = json.loads(marker.read_text())
        for entry in entries:
            path = target / entry["name"]
            if path.parent != target or path.is_symlink() or hashlib.sha256(path.read_bytes()).hexdigest() != entry["sha256"]:
                raise ValueError("Refusing to remove altered/out-of-scope analysis snapshot")
            path.unlink()
        marker.unlink()
        target.rmdir()  # Non-recursive; refuses unexpected files.
        return
    if target.exists():
        raise ValueError("Refusing to overwrite an existing analysis directory")
    target.mkdir()
    sources = [ROOT / item[1] for item in SUITES.values() if item[1].endswith(".dart")]
    sources.append(ROOT / "packages/ventio_host_api/test/engineering_audit.dart")
    sources += list((ROOT / "packages/ventio_core/test/support").glob("wave2*.dart"))
    sources += list((ROOT / "packages/ventio_host_api/test/support").glob("wave2*.dart"))
    sources += list((ROOT / "packages/ventio_native_client/test/support").glob("wave2*.dart"))
    sources = sorted(set(sources))
    entries = []
    for index, source in enumerate(sources):
        text = source.read_text(encoding="utf-8-sig")
        def rewrite(match: re.Match) -> str:
            prefix, uri = match.groups()
            return prefix + "'" + ((source.parent / uri).resolve().as_uri() if not re.match(r"^[A-Za-z][A-Za-z0-9+.-]*:", uri) else uri) + "'"
        text = re.sub(r"((?:import|export)\s+)'([^']+)'", rewrite, text)
        name = f"source_{index:02d}.dart"
        contents = ("// Static analysis copy. Never execute this file.\n" + text).encode()
        (target / name).write_bytes(contents)
        entries.append({"name": name, "source": source.relative_to(ROOT).as_posix(), "sha256": hashlib.sha256(contents).hexdigest()})
    marker.write_text(json.dumps(entries, indent=2) + "\n")

def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--write-matrix", action="store_true")
    parser.add_argument("--analysis-snapshots", action="store_true")
    parser.add_argument("--clean-analysis-snapshots", action="store_true")
    args = parser.parse_args()
    if args.analysis_snapshots or args.clean_analysis_snapshots:
        analysis_snapshots(clean=args.clean_analysis_snapshots)
        print("Static analysis source copies prepared/removed; no test execution.")
        return
    data = matrix(collect())
    json_path = DOCS / "WAVE_2_B_PREPARED_CASES.json"
    md_path = DOCS / "WAVE_2_B_PREPARED_COVERAGE.md"
    encoded = json.dumps(data, indent=2, ensure_ascii=False) + "\n"
    rendered = markdown(data)
    if args.write_matrix:
        json_path.write_text(encoded, encoding="utf-8")
        md_path.write_text(rendered, encoding="utf-8")
    else:
        if json_path.read_text(encoding="utf-8") != encoded or md_path.read_text(encoding="utf-8") != rendered:
            raise ValueError("Prepared matrix differs from literal source inventory")
    print(f"Static inventory: {data['automatedCaseCount']} prepared cases; 22 capabilities; 0 executed by this validator.")

if __name__ == "__main__":
    main()
