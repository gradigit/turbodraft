# TurboDraft editor E2E UX methodology

This benchmark measures true user-flow latency for the external-editor loop, not just RPC microbenchmarks.
Use this as an integration/reliability benchmark. For strict startup performance, use `startup-trace-methodology.md`.

## Flow under test

1. Harness text view receives `Ctrl+G`
2. Harness launches `turbodraft open --wait --path <fixture>`
3. TurboDraft becomes frontmost and editable
4. Automation types one character, saves, and closes TurboDraft
5. Harness regains focus and text cursor is restored

## Metrics

- `ctrlGToTurboDraftActiveMs`: Ctrl+G to TurboDraft app activation
- `ctrlGToEditorWaitReturnMs`: Ctrl+G to `turbodraft open --wait` completion
- `ctrlGToHarnessReactivatedMs`: Ctrl+G to harness app reactivation
- `ctrlGToTextFocusMs`: Ctrl+G to harness text cursor restored
- `phaseTurboDraftInteractionMs`: TurboDraft active -> external editor loop complete
- `phaseReturnToHarnessMs`: editor loop complete -> harness/text focus restored
- `phaseEndToEndRoundTripMs`: full Ctrl+G -> harness text focus

## Statistical method

- p95: nearest-rank percentile
- median CI: bootstrap 95% confidence interval (2000 rounds)
- cold and warm runs are reported separately
- p95 is computed from valid runs only

## Cold vs warm handling

- Cold run: kill `turbodraft-app` + remove socket before each sample
- Warm run: keep resident app path for repeated samples

## Validity gates

- A run is valid only if:
  - `returnCode == 0`
  - unique typed token is present in fixture file after close (proves edit actually happened)
  - key metrics are present (`ctrlGToTurboDraftActiveMs`, `ctrlGToTextFocusMs`)
- The suite retries until target valid samples are reached (or max attempts exceeded).
- Gate thresholds:
  - minimum valid run count per mode (configured by `--cold` / `--warm`)
  - minimum valid rate per mode (default `--min-valid-rate 0.95`)

## Constraints

- Requires macOS Accessibility permission for terminal automation (`osascript` via System Events).
- Character insertion validation is performed by checking fixture text changed after each run.
