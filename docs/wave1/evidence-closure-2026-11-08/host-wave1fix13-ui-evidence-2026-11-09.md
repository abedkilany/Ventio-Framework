# Wave1fix13 Physical Host UI Inspection — 2026-11-09

## Procedure and machine identity

Opened a Remote Desktop Connection to `192.168.1.102`; RDP window title was `192.168.1.102 - Remote Desktop Connection`. The saved RDP identity shown by the connection dialog was `abedkilany\abedkilany`. In the remote desktop, Command Prompt displayed Windows version `10.0.26300.9711`; `hostname` returned:

```text
AbedKilany
```

This is the same Host verified by SSH as `ABEDKILANY` (Windows hostname comparison is case-insensitive). Ventio was launched from the Host desktop; application window title: `ventio native client`.

## Visible Ventio home and access state

The home page displayed:

```text
Host profile selected · AB
Selected scope: CD / EF. Host access requires a verified session.
Local drafts and records stay provisional; only Host-approved packages can be installed from the registry.
```

The Home page did not show an authenticated identity. The Host Overview action was not visible. Source inspection confirms Overview is exposed only when a persistent verified identity has `host.status.read` for the exact company/branch scope (`packages/ventio_native_client/lib/src/extension_studio_page.dart`, `_canReadHostStatus`). No credential or pairing code was entered.

## Host Setup page

The UI showed PostgreSQL service **Running** and Ventio Host service **Running**. The six setup progress indicators were empty for Windows setup approval, PostgreSQL, Ventio Host, first Host administrator, secure administrator credential storage, and Host readiness verification. The visible Initial Host scope fields for tenant, company, and branch were blank (`0/256` each). The **Set up Host** button was disabled. No setup action was started and no service, database, scope, or credential state was changed.

Observed UI state: service processes are running, but this screen provides no overall READY result and shows the first-run lifecycle incomplete. This does not prove that no administrator exists in the Host database; the UI has no verified session and the setup form has not been submitted.

## Host Settings page

The visible local Host profile showed address `http://127.0.0.1:8080`, tenant `AB`, company `CD`, branch `EF`. The LAN listener card showed:

```text
HTTPS endpoint: https://ABEDKILANY:8443
Current private IP endpoints:
  https://172.31.192.1:8443
  https://192.168.1.102:8443
TLS certificate SHA-256:
  703297d631e194a071d107cc56c762f86a1bb6df4177252cdf06f61ce87e18f6
```

## Version and acceptance disposition

No application version was visible on the observed Ventio pages. Product registry version `0.1.18` remains CLI evidence; it is not claimed as a GUI-displayed version. The Host Overview readiness/version requirement is **BLOCKED — ENVIRONMENT** because the application has no verified session with the required exact-scope readiness permission. Stage 3 remains open; the displayed setup state is incomplete. Stage 10, 8, and 9 remain open. RDP screenshots were observed through Computer Use in this session; no screenshot image was saved as a standalone file.
