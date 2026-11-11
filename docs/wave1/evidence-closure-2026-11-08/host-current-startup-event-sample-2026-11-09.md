# Host Current Startup Event Sample — 2026-11-09

## Procedure and scope

Using authenticated SSH and read-only PowerShell, queried the 200 newest records in the Windows Application log. This intentionally bounded sample was filtered locally for PostgreSQL provider events; the event XML was checked for the previously observed PostgreSQL SQLSTATE `42883` and routine `list_extension_submissions`. No event payloads containing request data were exported.

## Observed output

```text
APPLICATION_EVENTS_SAMPLED=200
POSTGRES_EVENTS_IN_SAMPLE=85
MISSING_ROUTINE_SIGNATURE_EVENTS_IN_SAMPLE=0
```

The newest sampled PostgreSQL records were dated `2026-11-09T12:33:50Z` through `2026-11-09T12:39:16Z` (Windows Application event time). The provider exposes blank message and level fields in this event view; this procedure therefore checks only for the two known failure signatures in the sampled event XML.

## Classification and limits

**PASS — VERIFIED** that the previously diagnosed missing-routine signature was absent from the XML of the 85 PostgreSQL events within the newest 200 Application records sampled. This does not establish that all PostgreSQL errors were absent, that the sample covers the complete Host startup interval, or that the Host management-readiness route is ready. No service, database, or configuration was modified.

## UI access attempt

A supported Computer Use attempt to activate the existing Explorer window failed with `GetCursorPos failed: Access is denied. (0x80070005)`. The current window inventory contained no Host RDP/Ventio window. No UI input or setup action was sent; Host Overview remains unverified.
