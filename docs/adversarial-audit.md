# Adversarial implementation audit

Audited against `.idea/factory_hoist-design.md` on 2026-09-01.

## Verified

| Requirement | Evidence |
|---|---|
| RSpec declaration collection, selected-example reference analysis, dependency propagation, and LCA scheduling | Tests for unused, descendant-only, reverse-ordered dependencies, filtered single-example runs, and dynamic references |
| Safe fallback for dynamic inputs and unsupported factories | RSpec `let`, instance variables, custom Marshal failures, `initialize_with`, and `to_create` all deopt locally |
| Group/example savepoints, context-hook isolation, rollback, and configurable rebuild budget | SQLite tests cover before/after context ordering, partial materialization failure, and local ActiveRecord rollback |
| PostgreSQL subxid budget | 61 writes, one rebuild, no added `Subtrans` reads; `pg_stat_activity`, `txid_current_if_assigned`, and `pg_control_checkpoint` verified |
| Lazy graph copy with relationship identity and per-example memoization | RSpec integration tests |
| Deterministic node/key seed | BLAKE2b-based seed test; Faker random source is scoped when Faker is loaded |
| PCG random source | Canonical PCG32 vector, boundary tests, reset reproducibility, and thread-isolated Faker scopes |
| Failure locality | Materialization errors include the declaration node and key |
| FactoryBot build/create/list compatibility | Unit and ActiveRecord integration tests |
| Fast Build | Generated Ruby file, generated-file backtraces, reload-safe constants, conservative fallback; fixed benchmark above 5x |
| Bulk Writer | ActiveRecord `insert_all!`, native type casting, row diagnosis, and PostgreSQL outer-transaction recovery after failure |
| DatabaseCleaner warning and paranoid row checks | Unit and ActiveRecord integration tests |
| RSpec and Minitest correctness | RSpec sharing; Minitest deliberately deoptimizes to per-test creation |
| Packaging and CLI | Gem build and packaged executable checks |
| Process-parallel database initialization | SQLite locked exclusive no-overwrite copy and PostgreSQL advisory-locked template clone; PostgreSQL verified with temporary databases |
| Phase 0 harness | Reproducible synthetic three-way benchmark in `docs/phase0-synthetic.md` |

## Not claimable from this repository

These are empirical acceptance gates, not library code:

- G1's 60% record reduction, the 50% duplication stop condition, and the 30% dynamic-argument stop condition require the target application's full test suite.
- Comparison against mechanically applied `let_it_be` plus `build_stubbed`, representative single-file timings, RSS, and three-run suite medians require that same suite.
- MySQL behavior cannot be verified because no MySQL server is available in this environment.

## Contradictions in the design

- G2/G4 require no migration and an unchanged suite, while §3.2 requires explicit `hoist` declarations and §4.1 requires mechanical replacement. Both cannot be true simultaneously.
- `ActiveRecord::Base.instantiate` creates an object treated as persisted, which does not preserve FactoryBot `build` semantics for a row that does not exist. Fast Build uses `new` and real model instances instead.
- Generic circular-FK `INSERT + UPDATE` is impossible when both foreign keys are immediately enforced and non-null. It requires nullable/deferred constraints or preallocated keys, none of which the API or design specifies.

## Deliberate safe degradation

- Minitest cross-test sharing is disabled because the design leaves its portable group tree/lifecycle unresolved. The compatibility path remains correct and reports deoptimization.
- Static reference analysis uses MRI bytecode. Dynamic, indirect, and non-MRI block declarations take the correct local fallback.

## Verdict

The repository is implementation-complete for the coherent, testable subset and exposes runnable checks for SQLite, PostgreSQL, database cloning, Phase 0, and Fast Build. The design as written cannot be completely satisfied because of the contradictions above. Product-level completion also remains blocked on the mandatory target-suite measurements; claiming G1/G2 or the project stop/go decision without that input would be false.
