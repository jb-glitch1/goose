# Rust core — test status

`cargo test --lib` (13 unit tests) is **green**, and the reference-adapter
tests pass after the `importlib.util` fix. The remaining **integration** tests
fail in a clean checkout for two reasons, neither caused by app logic changes
in this branch. CI therefore runs the lib + reference tests (always green) and
this document tracks the rest.

Reproduce the full picture:
```sh
cd Rust/core && cargo test --no-fail-fast
```

## Already fixed in this branch

- `command_tests::command_definitions_cover_generated_protocol_command_map_ids`
  — had a wrong `include_str!` path (4 `../`, resolved outside the repo) and
  depended on an uncommitted generated file. Now reads at runtime and **skips
  gracefully** when the artifact is absent.
- `reference_tests` / `reference_runner_cli_tests` (6 tests) — the Python
  adapters imported `importlib` but used `importlib.util.find_spec`. Fixed by
  importing `importlib.util`; they now degrade to their documented
  "missing"/"test-fallback" contract without the optional scientific libraries.

## Category A — missing uncommitted artifacts (environmental)

These read files the upstream author kept locally and never committed. They
cannot pass in a clean checkout. **Fix:** obtain/commit the artifact, regenerate
it, or convert each to skip-when-absent (as done for the command-map test).

| Test (file) | Missing path |
|---|---|
| `bridge_runs_ui_coverage_audit_for_debug_coverage_surface` (`bridge_tests.rs`) | `apk-ui-inventory/coverage-map.json` |
| `command_capture_plan_cli_emits_selected_command_plan` (`command_capture_plan_cli_tests.rs`) | `Rust/fixtures/command-evidence/whoop-emulator-command-evidence.json` |
| `command_capture_plan_summarizes_emulator_evidence_promotion_work` (`command_tests.rs`) | same emulator fixture |
| `command_validator_cli_can_emit_capture_plan_for_selected_commands` (`command_tests.rs`) | same emulator fixture |
| `official_app_emulator_fixture_promotes_validated_shortcut_commands` (`command_tests.rs`) | same emulator fixture |
| `ios_health_metric_display_filters_forbidden_metric_sources` (`ios_healthkit_boundary_tests.rs`) | `goose-swift/GooseSwift/HealthDataStore+Utilities.swift` |
| `ios_healthkit_read_boundary_is_weight_only` (`ios_healthkit_boundary_tests.rs`) | `goose-swift/GooseSwift/` (Swift source dir) |
| `local_health_validation_example_manifest_covers_controlled_step_matrix` (`local_health_validation_suite_cli_tests.rs`) | `Rust/docs/local-health-validation-manifest.example.json` |
| `testing_strategy_names_scriptable_tools_for_bridge_gates` (`tooling_inventory_tests.rs`) | `Rust/docs/testing-and-tooling-strategy.md` |

Note: the two `ios_healthkit_boundary_tests` look for Swift sources under
`goose-swift/GooseSwift/`, but this repo has them at `GooseSwift/` (repo root) —
a layout mismatch, likely from how the upstream tree was arranged. Adjust the
test paths or the layout.

## Category B — real logic conflict (needs a decision) ⚠️

These are **not** missing files. They hit a deliberate privacy guard in
`Rust/core/src/store.rs` (`validate_no_official_whoop_label_marker`) that rejects
any `official_whoop_*` marker from being stored in a local metric's JSON —
core to the "never present WHOOP's data as our own" design. But the
step-validation feature legitimately uses the WHOOP app's step count as a
comparison **label**. The two collide when writing the metric.

| Test |
|---|
| `bridge_writes_validated_raw_motion_step_estimate_as_local_activity_metric` (`bridge_tests.rs`) |
| `raw_motion_step_estimator_writes_validated_local_estimate_metric_when_requested` (`step_motion_estimator_tests.rs`) |
| `local_health_validation_suite_applies_manifest_case_defaults` (`local_health_validation_suite_cli_tests.rs`) |
| `local_health_validation_suite_imports_capture_sqlite_before_running_cases` (`local_health_validation_suite_cli_tests.rs`) |

**Not fixed on purpose** — resolving this either loosens a privacy guarantee or
changes how validation labels are stored, which is a design call for the
maintainer. Decide the intended behavior, then fix the store path (e.g. keep
official labels out of the stored metric JSON while still using them for
validation) rather than weakening the guard.
