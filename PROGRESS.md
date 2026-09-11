# Duo More Thing — iPhone Duo fold-blur effect on a MacBook

Progress file for handing work between agents. Update on every significant step.

## Goal
Reproduce the iPhone Duo animation on a MacBook: as the lid closes, the upper
part of the interface progressively blurs and falls into shadow, with the blur
gradient dying out toward the bottom edge of the screen (the hinge axis). On
open, it reverses. The effect is tied to the real physical lid angle.

## Key findings (research, 2026-09-11)

### 1. The lid-angle sensor EXISTS and is available from user space
Introduced with the MacBook Pro 16" 2019. Reverse engineering:
samhenrigold/LidAngleSensor. Access: IOKit HID, **feature report** (not input
report).

- Vendor ID `0x05AC`, Product ID `0x8104`
- PrimaryUsagePage `0x20` (Sensor), PrimaryUsage `0x8A` (Orientation)
- `IOHIDDeviceGetReport(dev, kIOHIDReportTypeFeature, reportID: 1, buf, &len)`
- 3-byte reply: `[0x01, lo, hi]` → angle = `UInt16(hi) << 8 | UInt16(lo)` in DEGREES
- 0° = closed, ~130° = typical working position

### 2. VERIFIED on this machine (Mac14,9 = MacBook Pro 14" M2 Pro, macOS 26.6.2)
`scratchpad/probe.swift` enumerated HID devices. Result:
```
vid=0x05AC pid=0x8104 page=0x20 usage=0x8A   <== THE ONE
   feature report id=1 len=3 bytes=[1, 130, 0] -> angle=130   ✅ WORKS
   feature report id=2 len=2 bytes=[2, 39, 0]
   feature report id=3 len=6 bytes=[3, 130, 169, 136, 1, 0]  (maybe sub-degree: 130 + 169/256?)
```
Conclusion: NO camera needed, NO hacks. The angle is read directly, 60 Hz.
(Three other devices with pid=0x8104 and page=0xFF00 return error 0xE00002C7
on feature report — skip those and match strictly on page=0x20 / usage=0x8A.)

### 3. Existing prototypes (reference, not our code)
- `lqSky7/iphone-duo-macos-animation` (macTilt) — exactly this task, Swift +
  Metal + ScreenCaptureKit, ~2850 lines, 3D fold perspective, liquid-glass
  panel, menu bar. Cloned to `<scratchpad>/mactilt` for study. The HID device
  matching scheme was taken from there.
- `samhenrigold/LidAngleSensor` — original source for the sensor.
- Original effect parameters (from Android-reconstruction writeups):
  max blur radius ~72 source pixels, darkening = 2× transition strength
  clamped to black, blur and darkening follow image coordinates.

## Architecture
The real system UI cannot be blurred with public APIs. So: an overlay window
above everything (`CGShieldingWindowLevel`) with a frozen screen capture,
drawn in Metal with a progressive blur.

- Capture: ScreenCaptureKit `SCScreenshotManager.captureImage` at “arming”
  (angle dropped below startAngle+20° while closing) — before the overlay is
  shown, so the overlay is not in the frame. Fallback without Screen Recording
  permission: the wallpaper.
- Blur: mip pyramid (`MPSImageGaussianPyramid`) + variable-LOD sampling in the
  fragment shader = a real variable blur, cheap on the GPU.
- Gradient model (v1): d = distance from the hinge (bottom of the screen) 0…1,
  s = fold strength 0…1, W = gradient width,
  `p = (1-s)*(1+W) - W`, `n = smoothstep(saturate((d-p)/W))`,
  `lod = n^gamma * maxLod`, darkening = smoothstep on n.
  At s=0 there is no blur anywhere; at s=1 blur is maximum everywhere.
- Plus a slight squash of the image toward the hinge — a fake camera angle.

## Status

- [x] Research: sensor, APIs, references
- [x] Sensor check on the user’s hardware — WORKS (130°)
- [x] App skeleton Duo More Thing.app (menu bar, LSUIElement)
- [x] LidAngleSensor.swift
- [x] ScreenSource.swift (SCScreenshotManager + wallpaper fallback)
- [x] FoldRenderer.swift + Shaders/Fold.metal
- [x] OverlayController (CGShieldingWindowLevel, mouse-through)
- [x] Tuning window + manual effect-strength scrub
- [x] build.sh, build and launch verified
- [x] Offscreen `--render-test` for parameter picking
- [x] Safety: release the screen if the lid sits still (releaseDelay)
- [ ] **NOT VERIFIED LIVE: real lid close/open** — needs a human
- [ ] Not verified: behavior after sleep and on the lock screen
- [ ] Screen Recording permission is granted by the user (see below)

## What was verified, and how

- Sensor: `scratchpad/probe.swift`, angle reads, 130°.
- Effect: `--render-test` on a real desktop screenshot, 6 stages — the gradient
  and darkening look like iPhone Duo.
- Live overlay: `open "build/Duo More Thing.app" --args --hold 0.55` +
  `screencapture` — the window covers everything, including the menu bar;
  the effect is visible.
- Actual lid motion cannot be tested from an agent.

## Tuned defaults (Settings.swift, later superseded)
startAngle 90°, endAngle 20°, maxLod 7 (128 px), gradientWidth 0.85,
gamma 1.4, frontCurve 1.5, darkness 0.95, darkStart 0.5, squash 0.07,
followSpeed 26, releaseDelay 2.5 s.

`frontCurve` was an important parameter: >1 keeps sharpness at the hinge
longer, otherwise at 80% fold the whole screen is already black (the first
version looked like that).

## Known permission trap
TCC attributes the Screen Recording request to the “responsible” process. If
you launch the app from a terminal/agent, the dialog arrives on behalf of the
parent (ours was “Claude”). Launch from Finder/Spotlight. Until permission is
granted, the wallpaper fallback runs — the effect is visible, but the
wallpaper stands in for the UI.

## Iteration 2 (from feedback)

What was asked, and what was done:

1. **“The UI disappears, only the background remains”** — that was the
   wallpaper fallback: Screen Recording was not granted, and the app
   degraded silently. Source state is now always visible (“live screen” /
   “wallpaper” pill, a reason string, a grant button). Only the user can
   grant the permission, and only by launching the app from Finder.
2. **3D perspective.** The frame is drawn as a quad rotated around the bottom
   edge (the hinge) and projected in perspective. The projection is chosen so
   that at strength = 0 the panel matches the screen pixel for pixel:
   `f = 2·depth`, so at θ=0 the panel corners land exactly on NDC ±1. Then
   the panel recedes; around it is the void (black, or the room photo).
3. **The effect should hit harder at the start.** The old model (a traveling
   blur front) did not separate “how fast the top blurs” from “how long the
   hinge stays sharp”, so the top started blurring late. Replaced with two
   independent curves:
   `n = mix(s^hingeCurve, s^topCurve, d^shape)`, where topCurve < 1 gives a
   snappy response at the far edge and hingeCurve > 1 holds sharpness at the
   hinge. Old parameters gradientWidth / gamma / frontCurve / squash removed.
4. **Liquid Glass settings panel.** SwiftUI, `glassEffect` +
   `GlassEffectContainer`, backdrop = a blurred screen capture (otherwise
   the glass has nothing to refract and looks like a flat rectangle). Live
   effect preview with a strength slider, rendered offscreen with the same
   shader. The old TuningWindow is gone. Deployment target raised to
   macOS 26.0 for these APIs.

New defaults: startAngle 100°, endAngle 18°, armLead 30°, maxLod 7.2,
topCurve 0.45, hingeCurve 4.5, shape 1.6, darkness 0.97, darkStart 0.45,
tiltAngle 38°, tiltCurve 1.3, depth 2.2, followSpeed 26, releaseDelay 2.5 s.

Verified: build, panel (screenshot docs/panel.png), offscreen render of every
stage, live sensor (125–130°). Still not verified: real lid motion, behavior
after sleep and on the lock screen, running with Screen Recording granted
(only the user can grant that).

## Later iterations

- Side rims of the perspective panel dissolve into the void (and into the
  room photo when that is on). Slider: Side fade.
- A held *real* fold no longer auto-releases; only a slight fold does, and
  the default timeout is 8 s (`never` at 15).
- Settings sliders are real `NSSlider`s; the window is not movable by
  background, so dragging a slider no longer drags the window.
- **Room behind the fold** (on by default): FaceTime still, on-device person
  removal, blurred room drawn behind the panel. No camera permission (or
  capture failure): blurred desktop wallpaper. Toggle off: black void.

## What could be done next
