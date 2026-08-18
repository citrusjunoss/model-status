# Design QA

## Evidence

- Source visual truth: `/var/folders/7x/jcrf3z7147s2r2__50fj3yx80000gn/T/codex-clipboard-4040951f-5198-48e4-b201-4a4ba9c81e71.png`
- Implementation screenshot: `/private/tmp/model-status-orb.png`
- Combined comparison: `/private/tmp/input-status-design-comparison.png`
- Source pixels: 282 x 244; implementation pixels: 208 x 208.
- Implementation viewport: 104 x 104 pt at 2x density.
- Comparison normalization: source scaled to 540 x 444 and implementation scaled to 444 x 444 for a side-by-side placement comparison.
- State: online, stable, 428 ms latency. The source quota value and implementation quota value intentionally differ.

## Full-View Comparison

The implementation places the latency readout in the same bottom ring gap marked by the source. The fixed 80-degree gap remains free at 100% progress, so the text does not collide with the latency arc or its endpoint ticks.

## Focused Region Comparison

The bottom gap was reviewed at enlarged scale. Characters follow the ring curvature, the center characters remain nearly horizontal, and the outer characters rotate along the tangent. Normal, low-quota, interrupted, and failed states were captured; no text overlaps the center gauge, progress arc, or stability ring.

## Required Fidelity Surfaces

- Fonts and typography: compact monospaced digits match the existing instrument typography; weight and size remain legible at 104 pt.
- Spacing and layout: the readout is centered in the bottom gap with clearance from both progress endpoints.
- Colors and tokens: the readout reuses the existing green, amber, red, and gray semantic status colors.
- Image quality and assets: native Core Graphics rendering remains sharp at 2x; no new raster asset is introduced into the component.
- Copy and content: online states show compact latency, failed shows `失败`, and unknown shows `--`.

## Findings

No actionable P0, P1, or P2 differences remain.

## Comparison History

- First pass: latency text was inside the center liquid gauge, which did not match the marked target region.
- Fix: moved the readout into the fixed bottom gap and changed it from a straight line to tangent-aligned curved text.
- Post-fix evidence: `/private/tmp/input-status-design-comparison.png`, plus low-quota and failed captures in `/private/tmp/model-status-orb-low.png` and `/private/tmp/model-status-orb-failed.png`.

## Follow-Up Polish

No blocking polish items.

final result: passed
