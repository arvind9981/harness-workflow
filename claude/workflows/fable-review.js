export const meta = {
  name: 'fable-review',
  description: 'Review the current working-tree diff — Sonnet finders by dimension, Fable adversarially verifies and synthesizes',
  phases: [
    { title: 'Review', detail: 'Sonnet finders review the diff by dimension' },
    { title: 'Verify', detail: 'Fable adversarially checks each finding', model: 'fable' },
    { title: 'Synthesize', detail: 'Fable ranks the confirmed findings', model: 'fable' },
  ],
}

// Optional args: { target: "HEAD" | "origin/master" | "<ref>" } — what to diff against.
// Default HEAD reviews the uncommitted working-tree change set.
const target = (typeof args === 'object' && args && args.target) ? String(args.target) : 'HEAD'

const FIND_SCHEMA = {
  type: 'object', additionalProperties: false,
  properties: {
    dimension: { type: 'string' },
    findings: { type: 'array', items: {
      type: 'object', additionalProperties: false,
      properties: {
        file: { type: 'string' },
        line: { type: 'integer' },
        summary: { type: 'string' },
        failure_scenario: { type: 'string' },
        suggested_fix: { type: 'string' },
        severity: { type: 'string', enum: ['high', 'medium', 'low'] },
      },
      required: ['file', 'summary', 'failure_scenario', 'severity'],
    } },
  },
  required: ['dimension', 'findings'],
}

const VERDICT_SCHEMA = {
  type: 'object', additionalProperties: false,
  properties: {
    real: { type: 'boolean' },
    severity: { type: 'string', enum: ['high', 'medium', 'low'] },
    reason: { type: 'string' },
    refined_fix: { type: 'string' },
  },
  required: ['real', 'severity', 'reason'],
}

const SYNTH_SCHEMA = {
  type: 'object', additionalProperties: false,
  properties: {
    summary: { type: 'string' },
    findings: { type: 'array', items: {
      type: 'object', additionalProperties: false,
      properties: {
        rank: { type: 'integer' },
        file: { type: 'string' },
        line: { type: 'integer' },
        severity: { type: 'string', enum: ['high', 'medium', 'low'] },
        problem: { type: 'string' },
        failure: { type: 'string' },
        fix: { type: 'string' },
      },
      required: ['rank', 'file', 'severity', 'problem', 'fix'],
    } },
  },
  required: ['summary', 'findings'],
}

const DIMENSIONS = [
  { key: 'correctness', focus: 'Logic errors, wrong conditions, off-by-one, unhandled edge cases, broken error paths, regressions, incorrect API usage.' },
  { key: 'simplification', focus: 'Dead code, duplication, needless complexity, reinvented helpers, a clearer equivalent, over-engineering.' },
  { key: 'efficiency', focus: 'Wasted work, repeated computation, unnecessary allocations or IO, per-call cost that should be hoisted or cached.' },
]

// ── Phase 1: dimension finders (Sonnet) read the real diff and review ────────
phase('Review')
const reviews = (await parallel(DIMENSIONS.map((d) => () =>
  agent(
    `Review the current change set in this repo for ${d.key.toUpperCase()} issues.\n` +
    `First run \`git --no-pager diff ${target}\` (and \`git --no-pager diff --stat ${target}\` for scope) to see exactly what changed, and read the surrounding code as needed to judge. ONLY report issues introduced or touched by this diff — not pre-existing ones. Read-only; change nothing.\n\n` +
    `FOCUS: ${d.focus}\n\n` +
    `For each finding give: file, line, a one-sentence summary, a concrete failure scenario (specific inputs/state -> wrong result), and a suggested fix. Be precise and skip style nits. Return { dimension: "${d.key}", findings: [...] } (empty findings is fine).`,
    { label: `find:${d.key}`, phase: 'Review', model: 'sonnet', effort: 'medium', schema: FIND_SCHEMA })
))).filter(Boolean)

const findings = reviews.flatMap((r) => (r.findings || []).map((f) => ({ ...f, dimension: r.dimension })))
log(`${findings.length} candidate finding(s) from ${reviews.length}/${DIMENSIONS.length} finders`)

if (findings.length === 0) {
  return { target, candidates: 0, confirmed: 0, report: { summary: 'No issues found in the current diff.', findings: [] } }
}

// ── Phase 2: Fable adversarially verifies each finding against the real code ──
phase('Verify')
const verdicts = (await parallel(findings.map((f, i) => () =>
  agent(
    `Adversarially verify this code-review finding against the ACTUAL repo. Default real=false unless you can construct a concrete input/state that produces the claimed wrong behavior. Read the real code yourself (\`git --no-pager diff ${target}\` + the surrounding files) to confirm — do NOT trust the finding's own description. Read-only.\n\nFinding:\n${JSON.stringify(f)}`,
    { label: `verify:${(f.file || 'finding')}#${i}`, phase: 'Verify', model: 'fable', schema: VERDICT_SCHEMA })
    .then((v) => (v ? { ...f, verdict: v } : null))
))).filter(Boolean)

const confirmed = verdicts.filter((v) => v.verdict && v.verdict.real)
log(`${confirmed.length}/${verdicts.length} finding(s) confirmed by Fable`)

// ── Phase 3: Fable synthesizes a ranked, actionable review ───────────────────
phase('Synthesize')
const report = await agent(
  `You are the final reviewer (Fable). From these Fable-CONFIRMED findings on the current diff (target: ${target}), write a prioritized, actionable review. Rank by severity × confidence; merge duplicates; drop anything speculative. For each: file:line, the problem, the concrete failure it causes, and the fix. Keep 'summary' to 2-3 sentences.\n\nCONFIRMED:\n${JSON.stringify(confirmed.map((c) => ({ file: c.file, line: c.line, dimension: c.dimension, summary: c.summary, failure_scenario: c.failure_scenario, verdict: c.verdict })))}`,
  { label: 'synthesize', phase: 'Synthesize', model: 'fable', schema: SYNTH_SCHEMA })

return { target, candidates: findings.length, confirmed: confirmed.length, report }
