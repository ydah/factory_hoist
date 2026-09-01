# Synthetic Phase 0 report

Run on 2026-09-01 with `N=200`, in-memory SQLite, and three-run medians.

| Path | Median | INSERTs |
|---|---:|---:|
| FactoryBot | 0.0521s | 400 |
| `let_it_be` equivalent | 0.0126s | 2 |
| factory_hoist | 0.0244s | 2 |

- Record reduction: 99.5%
- Dynamic-argument rate: 0.0% in the synthetic fixture
- Tree depth: 1
- Writing examples per file: 200
- Fast Build separately measured above 5x FactoryBot

The synthetic workload passes the 60% record-reduction gate, but factory_hoist is slower than the `let_it_be` equivalent. The design's stop decision remains undetermined because the target suite, target duration, mechanical `build_stubbed` result, depth distribution, and application code are not present.

Reproduce with `bundle exec ruby bench/phase0_synthetic.rb`.
