# Wave 1 Closure Dashboard Refresh

The standalone dashboard is `docs/progress/wave1-host-client-progress.html`.

The closure checkpoint is rendered from `dashboard-state.json` by:

```powershell
python scripts/wave1/update_progress_dashboard.py
```

Run that command from the repository root after updating the checkpoint and appending evidence to `execution-history.jsonl`. The generator rewrites only the section between `WAVE1-CLOSURE-STATUS` markers. It does not claim automatic polling or browser live refresh; regenerate the HTML when the persisted state changes.
