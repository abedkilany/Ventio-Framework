"""Render the latest verified Wave 1 closure checkpoint into the standalone dashboard."""

from __future__ import annotations

import html
import json
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
DASHBOARD = ROOT / "docs/progress/wave1-host-client-progress.html"
STATE = ROOT / "docs/wave1/evidence-closure-2026-11-08/dashboard-state.json"
START = "<!-- WAVE1-CLOSURE-STATUS:START -->"
END = "<!-- WAVE1-CLOSURE-STATUS:END -->"


def esc(value: object) -> str:
    return html.escape(str(value), quote=True)


def render(state: dict) -> str:
    stage_rows = "\n".join(
        f"<tr><th>Stage {esc(stage)}</th><td>{esc(status)}</td></tr>"
        for stage, status in state["stageStatuses"].items()
    )
    operations = "\n".join(f"<li>{esc(item)}</li>" for item in state["completedOperations"])
    defects = "\n".join(f"<li>{esc(item)}</li>" for item in state["detectedDefects"])
    fixes = "\n".join(f"<li>{esc(item)}</li>" for item in state["implementedFixes"])
    evidence = "\n".join(
        f'<li><a href="../wave1/{esc(path)}">{esc(label)}</a></li>'
        for label, path in state["evidenceLinks"].items()
    )
    tests = state["tests"]
    return f"""<section class="card" aria-label="Wave 1 closure checkpoint">
  <h2>Wave 1 Closure Checkpoint</h2>
  <p><strong>Accepted progress:</strong> {esc(state['acceptedPercent'])}% (weighted stage ledger; unchanged until whole gates pass).</p>
  <p><strong>Current operation:</strong> {esc(state['currentOperation'])}</p>
  <p><strong>Latest verified checkpoint:</strong> {esc(state['latestCheckpoint'])}</p>
  <p><strong>Last updated:</strong> <time datetime="{esc(state['updatedAtUtc'])}">{esc(state['updatedAtLocal'])}</time></p>
  <div class="table-wrap"><table><thead><tr><th>Gate</th><th>Current status</th></tr></thead><tbody>
    {stage_rows}
  </tbody></table></div>
  <p><strong>Historical grouped closure runs:</strong> PASS {esc(tests['passed'])} · FAIL {esc(tests['failed'])} · BLOCKED {esc(tests['blocked'])} · NOT RUN {esc(tests['notRun'])}. These totals include superseded attempts.</p>
  <p><strong>Pending mandatory owner UI:</strong> {esc(state.get('ownerUiPending', 'See the owner checklist.'))}</p>
  <p><strong>Active limitations:</strong> {esc(state.get('activeLimitations', 'See the final acceptance report.'))}</p>
  <div class="grid">
    <section><h3>Completed operations</h3><ul>{operations}</ul></section>
    <section><h3>Detected defects</h3><ul>{defects}</ul></section>
    <section><h3>Implemented fixes</h3><ul>{fixes}</ul></section>
  </div>
  <h3>Supporting evidence</h3><ul>{evidence}</ul>
  <p class="muted">Refresh after appending an evidence event and updating dashboard-state.json: run <code>python scripts/wave1/update_progress_dashboard.py</code> from the repository root. This is a standalone HTML file; it does not refresh itself automatically.</p>
</section>"""


def main() -> None:
    state = json.loads(STATE.read_text(encoding="utf-8"))
    content = DASHBOARD.read_text(encoding="utf-8")
    replacement = START + "\n" + render(state) + "\n" + END
    if START in content and END in content:
        before, remainder = content.split(START, 1)
        _, after = remainder.split(END, 1)
        content = before + replacement + after
    else:
        anchor = '<div class="callout">'
        offset = content.find(anchor)
        if offset < 0:
            raise SystemExit("Dashboard insertion anchor was not found.")
        close = content.find("</div>", offset)
        if close < 0:
            raise SystemExit("Dashboard acceptance rule callout was not closed.")
        close += len("</div>")
        content = content[:close] + "\n" + replacement + content[close:]
    DASHBOARD.write_text(content, encoding="utf-8")
    print(f"Updated standalone dashboard: {DASHBOARD}")


if __name__ == "__main__":
    main()
