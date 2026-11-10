# Ventio Windows Performance Report — 2026-11-08

## Summary and evidence boundary

Release-build process-launch measurements are now available for the Client on the development workstation `BAHAA`: five fresh isolated-profile launches and five warm-profile launches. The process-launch to Flutter first-screen marker medians were 390.8 ms (fresh profile) and 340.2 ms (warm profile). The first fresh-profile launch was 1,566.0 ms and is retained in the raw evidence because it may represent first-run OS/image initialization. It was not dropped from the reported range. This evidence does not reproduce the target Client hardware or measure the Pairing Code, navigation, or Host Setup workflows end to end.

**Performance acceptance remains `BLOCKED — ENVIRONMENT`.** Pairing Code page initialization/generation, representative navigation, and initial Host Setup still require workflow captures on comparable Windows Release builds and an authorized disposable Host. No universal performance threshold is asserted.

## Hardware and method

- Windows 11 Pro, build 26300; Intel Core i7-10750H; 15.8 GiB RAM.
- Flutter Windows Release executable version `0.1.18+19`, captured from the process launch to `startup.first_screen.ready` JSONL event.
- Each cold run used a new isolated app-support directory. Each warm run reopened that exact marked directory; no database/profile was reset.
- Five pairs, in sequence, using the packaged `measure-ventio-performance.ps1`. Its 500 ms sampler captured process CPU, private bytes, working set, process I/O, plus available system CPU/disk/memory counters. Short launch runs yielded only two to four samples, too sparse to support sustained contention conclusions.
- Instrumentation was enabled through an environment opt-in and app events contain workflow labels, duration, timestamp and outcome only. App-side trace writes are flushed and may add a small measurement overhead.

## Comparable startup results

| Process launch to first-screen marker | Fresh isolated profile | Warm same profile |
|---|---:|---:|
| Five values (ms) | 1,566.0; 390.8; 336.9; 336.6; 415.4 | 331.8; 340.2; 348.3; 383.3; 340.2 |
| Median | 390.8 ms | 340.2 ms |
| Range | 336.6–1,566.0 ms | 331.8–383.3 ms |

Sampled peak process memory was approximately 123–125 MiB private and 96–97 MiB working set across these launches. The available-memory samples were approximately 5.95–6.03 GiB. Per-run system CPU/disk samples are too few and transient to characterize contention; the collector does not identify the physical disk type. CPU time and I/O are retained in JSON summaries for later paired analysis. The first fresh-profile run is substantially slower, so the median alone should not be treated as a worst-case startup guarantee.

## Earlier internal timing comparison

Before and after independent SQLite initialization was parallelized, internal app spans were captured in five pairs on the same local Windows workstation:

| Internal span | Before | After | Difference |
|---|---:|---:|---:|
| Cold Flutter binding → both local DBs ready | 34.0 ms | 30.2 ms | −3.8 ms |
| Warm Flutter binding → both local DBs ready | 27.0 ms | 25.1 ms | −1.9 ms |
| Cold Flutter binding → first screen ready | 65.5 ms | 59.6 ms | −5.9 ms |
| Warm Flutter binding → first screen ready | 59.1 ms | 58.1 ms | −1.0 ms |

These internal spans are not comparable to full process launch timings above. Cold per-database open spans increased under concurrent initialization because of contention, while the combined wall-clock startup spans shortened modestly. The improvement is small and does not explain all reported UI delays.

## Recovery Authority and Host request costs

The available isolated pairing request sample was about 2.98 s end-to-end and 2.35 s Host processing. Its reported stage breakdown was:

| Stage | Observed duration |
|---|---:|
| Authority lock and ACL helper setup | 832 ms |
| Independent witness read | 429 ms |
| Durable pending witness replacement | 471 ms |
| PostgreSQL transaction | 21 ms |
| Witness finalization | 480 ms |

Source inspection confirms Windows protected-file operations launch a noninteractive Windows PowerShell helper and perform ACL checks; the Recovery Authority serializes in-process and cross-process access with a file lock. A mutation reads the independent witness, writes a durable pending state, performs the PostgreSQL transaction, then finalizes the witness. Those costs are consistent with the observed spans. The transaction is not the dominant portion of this pairing sample.

No safe optimization to those guarantees is justified by current evidence. In particular, caching ACL checks, retaining an authority lock across requests, batching witness updates outside the admitted transaction, or weakening flush/replace semantics would change the security/crash model. The standalone subprocess and file operations are likely opportunities for a future measured implementation of an equivalent restricted native helper, but that is not a safe drop-in change without parity tests across ACLs, atomic replacement, process termination, DPAPI/service identities, and upgrade recovery. No such optimization was made or claimed here.

An isolated PostgreSQL profile previously reported fingerprint snapshot median 0.528 ms, RLS transaction 451.41 ms, and authenticated Host query 1,172.26 ms (five samples), with no comparable before value. These are fixture measurements, not the release Host service or target machine.

## Required workflow captures not yet available

| Workflow | Measurement status | Missing evidence |
|---|---|---|
| Full Client cold/warm process launch | `PASS — VERIFIED` on development workstation | Repeat on target Client under controlled power/network state |
| Representative page navigation | `NOT TESTED` | Per-route transition and page-ready timings, five comparable Release captures |
| Pairing Code page initialization | `NOT TESTED` | Page-local preparation, Host calls, TLS, DB and render spans on authorized test Host |
| Pairing Code generation | `NOT TESTED` | Client generation, Host request, Recovery Authority, PostgreSQL and response timing on disposable Host |
| Initial Host Setup and Administrator creation | `NOT TESTED` | Broker, service, migration, PostgreSQL, DPAPI, TLS provisioning/readiness stages on slow/representative Windows hardware |

The app timing probe records route transition durations, startup DB readiness, pairing-page/generation and Host Setup workflow marks when those paths are exercised. The packaged process collector adds system/process resource samples. Captures involving Host Setup or new pairing must use a disposable authorized Host because they create or alter Host state.

## Invalid early traces

Two exploratory collector traces reported negative launch-to-first-screen values due to an initial UTC parsing defect. They remain in the raw evidence folder for auditability, are explicitly invalid, and are excluded from every timing statistic above. A later direct-close exploratory trace is also retained but excluded from the five-pair sample. The corrected collector was then used for all ten reported paired launches.

## Conclusion

The measured local startup baseline is roughly 0.34–0.39 seconds after the first isolated-profile run, with one 1.57-second first cold process launch. The previously implemented parallel database startup saves only 1–6 ms in internal spans. Recovery Authority helper/lock/witness work is a measured cost center, but its integrity guarantees remain intact. Because the user-reported Pairing Code and Host Setup delays have not been measured in comparable Release workflows, the performance remediation objective is **not complete** and release remains blocked pending physical and isolated-Host captures.
