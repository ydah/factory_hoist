# Adversarial implementation audit

Audited against `.idea/factory_hoist-design.md` on 2026-09-01.

## Verified

| Requirement | Evidence |
|---|---|
| RSpec declaration collection, selected-example reference analysis, dependency propagation, and LCA scheduling | `Scheduler`; tests for unused, descendant-only, dependent, and dynamic references |
| Safe fallback for unanalyzable dynamic references and uncopyable values | Local per-example materialization; degradation counters |
| Group/example savepoints, context-hook isolation, rollback, and configurable rebuild budget | SQLite integration tests |
| PostgreSQL subxid budget | PostgreSQL 14: 61 writes, one outer transaction rebuild, zero added `Subtrans` reads, zero leaked rows |
| Lazy graph copy with relationship identity and per-example memoization | RSpec integration tests |
| Deterministic node/key seed | BLAKE2b-based seed test; Faker random source is scoped when Faker is loaded |
| Failure locality | Materialization errors include the declaration node and key |
| FactoryBot build/create/list compatibility | Unit and ActiveRecord integration tests |
| Fast Build | Generated Ruby file, runtime constant resolution after reload, conservative fallback; fixed benchmark above 5x |
| Bulk Writer | ActiveRecord `insert_all!`, type casting delegated to ActiveRecord, failed-row diagnosis without partial inserts |
| DatabaseCleaner warning and paranoid row checks | Unit and ActiveRecord integration tests |
| RSpec and Minitest correctness | RSpec sharing; Minitest deliberately deoptimizes to per-test creation |
| Packaging and CLI | Gem build and packaged executable checks |

## Not claimable from this repository

These are empirical acceptance gates, not library code:

- G1's 60% record reduction, the 50% duplication stop condition, and the 30% dynamic-argument stop condition require the target application's full test suite.
- Comparison against mechanically applied `let_it_be` plus `build_stubbed`, representative single-file timings, RSS, and three-run suite medians require that same suite.
- MySQL behavior cannot be verified because no MySQL server is available in this environment.

## Deliberate conditional omissions

- Process-parallel PostgreSQL template cloning is not shipped without a concrete worker/database lifecycle; guessing connection termination policy would risk data loss.
- Circular-FK bulk insertion is not generalized without a real schema. The design makes Bulk Writer conditional on Phase 0 showing persistence dominance.
- Minitest cross-test sharing is disabled because the design leaves its portable group tree/lifecycle unresolved. The compatibility path remains correct and reports deoptimization.
- Static reference analysis uses MRI bytecode. Dynamic or indirect calls take the correct local fallback; non-MRI runtimes conservatively schedule at the declaration boundary.

## Verdict

The repository is implementation-complete for the testable, safe core and exposes runnable checks for SQLite, PostgreSQL, and Fast Build. Product-level completion remains blocked on the design's mandatory Phase 0 target-suite measurements; claiming G1/G2 or the project stop/go decision without that input would be false.
