# CI ownership

## Purpose

Keep agent-setup validation independent of homelab deployments and runners.
The cleanup preserves agent model, generated-surface, and delegation tests while
retiring copied infrastructure workflows from active GitHub Actions discovery.

## Active workflows

- `agent-surface-drift.yml`: all PRs targeting main/master, mainline pushes, and
  manual runs; matrix and surface checks plus the Python suite on Python 3.12.
- `model-matrix-check.yml`: model/agent/workflow PR changes, mainline pushes, and
  manual runs; the same validation on Python 3.11.

The other 45 workflows, dependency lists, and three supporting composite actions
are archived under `.github/archived-homelab-workflows/`. This includes copied
Pages and Renovate automation: no Pages site was returned by the repository API,
and the inherited Renovate workflow references an absent `renovate.json`.
These snapshots are not a runnable deployment bundle. Live homelab automation
belongs to `Josh-Archer/home`.

## Acceptance criteria

- Only workflows owned by this repository remain under `.github/workflows/`.
- Agent validation runs on GitHub-hosted runners for pull requests and mainline pushes.
- Retired workflows remain available as clearly inactive reference material.
- A repository test rejects accidentally reintroducing an inherited workflow.
- Local checks and the cleanup PR's CI pass before handoff.

## Validation

```bash
python3 scripts/promote_model_matrix.py --check
python3 scripts/sync_agent_surfaces.py --check
python3 -m unittest discover -s scripts/tests -v
```

## Agent workflow trial

This maintenance change exercises bounded delegation on real work: the lead owns
implementation and integration; a junior investigator inventories CI ownership;
a separate junior reviewer checks the diff and validation gaps. Record observed
corrections and outcomes after review. One task is not enough to establish model
cost or speed advantages; keep the current Astra defaults until comparable tasks
provide stronger evidence.

### Observed result

The junior inventory identified 45 inherited workflows and their dependencies.
The lead archived them and added the ownership guard. The independent junior
review found no actionable issues and verified byte-for-byte workflow preservation.
The local suite passed 56 tests. No model or effort changes were needed.

This was one maintenance trial, not a controlled benchmark. Per-agent token
usage and a comparable single-agent timing baseline were not available, so it
provides no cost or speed conclusion. Keep the current defaults and compare
corrections, completion time, and usage on future comparable real tasks.
