# The Rem Harness — how this app is built

Rem is built almost entirely by **AI agents** (Claude Code), with a human acting as
director, reviewer, and taste-holder rather than line-by-line author. This folder is the
harness that makes that work: the working agreement the agents follow, and the hard-won
rules that keep AI-written code honest.

It's here in the open because the *method* is part of what Rem is. If you're building with
coding agents, this is a field-tested playbook, not a manifesto.

## The two-gate model

Velocity and correctness usually trade off. The harness splits them so they don't:

- **Gate 1 — the AI shipping gate.** A pass *separate from the builder* reviews the code
  and drives the real running product from a clean slate, capturing evidence. When both
  are green, the agent ships. The builder never merges its own unreviewed work.
- **Gate 2 — the human sampling gate.** The director spot-checks a sample and makes the
  calls only a human should — product, design, taste — *alongside* shipping, never as a
  per-PR merge button. What they catch becomes new issues, not a blocked queue.

## The rules that keep AI code honest

These are the expensive lessons, distilled. Each one cost real time before it became a rule.

- **Prove your test measures the thing.** Delete the fix, keep the test, run it. If it still
  passes, the test is worthless. A green check that measures nothing is the most expensive
  failure mode in agent-built code.
- **Adversarial review, not just independent review.** A second reader can agree with a
  wrong thing. A reviewer whose job is to *refute* — who deletes the fix and proves the test
  goes red — is the one that catches the green-but-dead change.
- **Agreement is not evidence.** In multi-agent work, N agents reading the same file and
  concurring is *one reading replicated*. Count measurements, not concurring voices. When
  agents converge without anyone having *run* something, that's the signal to go measure.
- **Read from the source of truth.** A stale local checkout produces a confident, wrong
  diagnosis. Cite the branch and line you actually read.
- **Prioritize; don't chase every fix.** A thorough review returns more than you should act
  on now. Ship the P0/P1s; file the rest. Chasing every nit turns one change into a stall.
- **Diagnose from evidence, not successive guesses.** Read the direct signal — the log line,
  the entitlements, the actual state — before asserting a cause. "I think it's X" said three
  times is worse than "let me check" said once.

## Files here

- [`AGENTS.md`](./AGENTS.md) — the full working agreement: delivery discipline, the two
  gates, the operating loop, and the field lessons above in their long form.
- [`CLAUDE.md`](./CLAUDE.md) — architecture context and per-feature gotchas the agents load
  before touching the code.

## Contributing with agents

You don't need to use agents to contribute to Rem — but if you do, this is how the
maintainers work, and PRs that follow it (adversarially reviewed, drive-verified, honest
about what's proven vs assumed) are the easiest to accept.
