# Adversarial implementation audit

Audited against `.idea/factory_hoist-design.md` on 2026-09-01.

## Verified

| Requirement | Evidence |
|---|---|
| RSpec declaration collection, selected-example reference analysis, dependency propagation, and LCA scheduling | Tests for unused, descendant-only, reverse-ordered dependencies, filtered single-example runs, and dynamic references |
| Safe fallback for dynamic inputs and unsupported factories | RSpec `let`, instance variables, custom Marshal failures, `initialize_with`, and `to_create` all deopt locally |
| Group/example savepoints, context-hook isolation, rollback, and configurable rebuild budget | SQLite tests cover hook ordering, late connections, reset cleanup, partial failures, local rollback, and leaking-row checks after failing hooks |
| PostgreSQL subxid budget | 61 writes, one rebuild, no added `Subtrans` reads; statistics, bulk recovery, and reset cleanup verified locally and in CI |
| Lazy graph copy with relationship identity and per-example memoization | RSpec integration tests |
| Deterministic node/key seed | BLAKE2b-based seed test; Faker random source is scoped when Faker is loaded |
| PCG random source | Canonical PCG32 vector, arbitrary-size integers, numeric ranges, real Faker inputs, reset reproducibility, and thread-isolated Faker scopes |
| Failure locality | Materialization errors include the declaration node and key |
| FactoryBot build/create/list compatibility | Unit and ActiveRecord integration tests |
| Fast Build | Bounded per-process paths, generated-file backtraces, reload-safe constants, association/alias semantics, evaluator-name collisions, and no retry after evaluator errors; benchmark above 8x |
| Bulk Writer | ActiveRecord `insert_all!`, native type casting, row diagnosis, and PostgreSQL outer-transaction recovery after failure |
| DatabaseCleaner warning and paranoid row checks | Unit and ActiveRecord tests, including mixed named/anonymous models |
| RSpec and Minitest correctness | RSpec sharing; Minitest deliberately deoptimizes to per-test creation |
| Packaging and CLI | Gem build, unpacked executable, and CI/full-suite coverage on the declared minimum Ruby 3.2 |
| Process-parallel database initialization | SQLite exclusive no-overwrite copy; PostgreSQL verifies active-source refusal, lock release, successful clone, and existing-target refusal |
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
- FactoryBot and database sequences are external mutable state. Node-seeding them would change their public values or ID strategy, while §6.2 requires the ID strategy to remain unchanged. The implementation node-seeds its PCG/Faker source only.

## Deliberate safe degradation

- Minitest cross-test sharing is disabled because the design leaves its portable group tree/lifecycle unresolved. The compatibility path remains correct and reports deoptimization.
- Static reference analysis uses MRI bytecode. Dynamic, indirect, and non-MRI block declarations take the correct local fallback.
- Fast Build keeps lazy attribute readers and a compatibility-only `method_missing` for model and FactoryBot helper methods instead of rewriting arbitrary Ruby blocks. Unsupported definitions fall back, while the 5x DoD remains enforced by the benchmark.
- Phase 4 attribute-level read tracking has no defined output after A1 rejects it for correctness decisions. The advisor instead reports declaration references, unused hoists, degradation, and materialization cost.

## Verdict

The repository is implementation-complete for the coherent, testable subset and exposes runnable checks for SQLite, PostgreSQL, database cloning, Phase 0, and Fast Build. The design as written cannot be completely satisfied because of the contradictions above. Product-level completion also remains blocked on the mandatory target-suite measurements; claiming G1/G2 or the project stop/go decision without that input would be false.
