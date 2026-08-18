# Design QA

- Source visual truth: `/Users/qzd/Documents/Codex/2026-08-05/ka/output/imagegen/model-status-orb-latency-gauge-v4.png`
- Orb default screenshot: `/Users/qzd/Documents/Codex/2026-08-05/ka/qa/model-status-orb.png`
- Orb hover screenshot: `/Users/qzd/Documents/Codex/2026-08-05/ka/qa/model-status-orb-hover.png`
- Orb hover information screenshot: `/Users/qzd/Documents/Codex/2026-08-05/ka/qa/model-status-orb-hover-info.png`
- Orb low-quota screenshot: `/Users/qzd/Documents/Codex/2026-08-05/ka/qa/model-status-orb-low.png`
- Orb no-data screenshot: `/Users/qzd/Documents/Codex/2026-08-05/ka/qa/model-status-orb-empty.png`
- Orb recent-interruption screenshot: `/Users/qzd/Documents/Codex/2026-08-05/ka/qa/model-status-orb-interrupted.png`
- Orb failed screenshot: `/Users/qzd/Documents/Codex/2026-08-05/ka/qa/model-status-orb-failed.png`
- Detail panel screenshot: `/Users/qzd/Documents/Codex/2026-08-05/ka/qa/model-status-view.png`
- Detail minimum-size screenshot: `/Users/qzd/Documents/Codex/2026-08-05/ka/qa/model-status-view-minimum.png`

## Comparison

The selected design board establishes a 104pt graphite-and-old-gold orb, a dark red remaining-quota liquid, and one Sol speedometer. The implementation uses the same dimensions and hierarchy with native AppKit drawing so the runtime stays small and does not add a browser engine.

The speedometer is deliberately inverse to latency: a smaller latency produces a longer active arc and places the brass pointer closer to the fast end. Online values below one second are green, higher online latency is amber, and only request failure is red. The separate thin outer track is continuous when the last hour was stable and segmented when a failure ended within the last hour.

The default QA state uses 63% remaining quota and Sol `428 ms`. The low-quota state changes the liquid to 12%, uses a red `6 天` label, and shows Sol `2.6 s`. Additional states cover a recent interruption, current failure, hover at `4.2 s`, and no data.

The detailed panel remains a 500 x 470 point AppKit view with a 430 x 450 minimum. Its quota result matches the confirmed calculation: current `$87.57`, other `$3.24`, remaining `$209.19`; total quota is used internally and is not rendered as a separate amount. The collapse control returns to the orb without changing its center position.

## Interaction checks

- Orb click opens the detailed panel in place; the explicit collapse icon returns to the orb.
- Dragging moves the panel only after a 3pt threshold, preventing click/drag ambiguity; each mode saves its own position and the detail mode saves its resized dimensions.
- Hovering the orb shows Sol latency, one-hour stability, and quota information in a separate floating panel that does not intercept dragging.
- Orb refresh cycles only Sol. Switching to detail immediately probes Terra, Lunna, and 5.5; detailed refresh cycles all four. Switching back cancels the three detail-only probes.
- The orb stays above ordinary application windows. The detailed panel returns to the desktop component level.
- The menu-bar item uses a fixed compact width derived from `5.5 9.9s`. It shows Sol in orb mode and keeps the independent five-second carousel in detail mode.
- Online latency below two seconds is green, latency at or above two seconds is amber, and request failure is red.

## Build checks

- `2.2.2 (10)` is present in both app bundles.
- Intel and arm64 executables are built as separate architecture-specific packages; no universal package is produced by the release script.
- Local QA bundles pass ad-hoc signature verification. Stable `ModelStatus Local Signing` initialization was blocked by the current keychain permission review and is not claimed for these bundles.
- The API key is read once from the versioned keychain service and reused from memory for refreshes.

## Findings

- Source type-check, universal/arm64 compilation, plist validation, architecture checks, and ad-hoc signature verification passed.
- Runtime window screenshots could not be regenerated in this environment because launching the temporary AppKit application was rejected by the desktop permission review. Existing QA screenshots are not treated as evidence for this implementation.

## Residual test gaps

- Live quota and probe values depend on a valid API Key and network access.
- A desktop session with permission to launch the app is still required to capture and visually inspect the new orb, hover panel, drag behavior, and always-on-top behavior.
- The actual subscription expiry field is provider-dependent. The decoder accepts date, timestamp, and remaining-day variants and displays `--` when none is present.
- The distributable stable-signature build remains pending because the local signing certificate could not be initialized in the current keychain permission context. The current local packages are ad-hoc signed and still require the expected first-launch trust action on another Mac.

final result: source-and-package checks passed; runtime visual QA and stable-signature packaging pending
