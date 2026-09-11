# Duo More Thing — the iPhone Duo fold effect on a MacBook

Close the MacBook lid and the interface folds around the bottom edge of the
screen: it recedes in perspective, blurs, and dissolves into the space behind
it — harder toward the top, sharper at the hinge. Open the lid and it unfolds.
The motion is driven by the real lid-angle sensor.

| 20% | 40% | 80% |
|---|---|---|
| ![](docs/fold-20.png) | ![](docs/fold-40.png) | ![](docs/fold-80.png) |

![settings panel](docs/panel.png)

## Build and run

```bash
./build.sh              # build to build/Duo More Thing.app
./build.sh install      # build and copy to /Applications
```

Requires Xcode Command Line Tools and macOS 26. A Metal toolchain is **not**
required — the shader is compiled at runtime from `Contents/Resources/Fold.metal`,
so you can edit it in the bundle and just relaunch.

The app lives in the menu bar and shows the current lid angle.

### Screen Recording permission is required

**Launch `Duo More Thing.app` from Finder or Spotlight.** If you start it from a
terminal or another app, macOS attributes the permission prompt to the parent
process, and Duo More Thing never appears in the list.

On first launch the system asks on its own. If that was missed, open the
settings panel (menu bar → Settings…) and click “Grant Screen Recording”, or
enable it by hand:

System Settings → Privacy & Security → Screen & System Audio Recording → Duo More Thing.

Without permission the app shows the **desktop wallpaper instead of the UI**.
The effect still runs, but it looks as if the interface vanished. The settings
panel always shows the source: a green “live screen” pill or an orange
“wallpaper” pill.

## Settings panel

Liquid Glass, with a live preview of the effect and a “Folded by” slider so you
can tune parameters without touching the lid.

**Lid angles** — where the effect starts, where the fold is complete, how many
degrees ahead the screenshot is taken, how quickly it follows the sensor, and
how long a *slightly* closed still lid waits before releasing the screen
(so you can still work with the lid a little down). A real fold (strength ≥ 0.25)
never auto-releases; set the slider to **never** to turn the safety off entirely.

**Blur** — maximum radius, plus separate response curves for the far edge
(below 1 blurs the top as soon as you start closing) and the hinge edge
(above 1 keeps the bottom sharp longer), and the shape of the gradient between
them.

**3D fold** — panel tilt at a full fold, the tilt easing curve, perspective
strength, and how hard the left/right (and far) rims dissolve into the void.

**Shadow** — depth and where the darkening begins.

**Background** — **Room behind the fold** is on by default. The FaceTime camera
photographs the room in front of the laptop; the person is removed on-device;
the hole is filled from the surrounding background; the still is heavily
blurred and drawn *behind* the folding panel. If camera permission is missing
(or the camera fails to open), the desktop wallpaper is used instead, also
blurred. Turn the toggle off for a black void. Launch the app from Finder.

## Launch flags (debugging)

```bash
open "build/Duo More Thing.app" --args --settings          # open the panel immediately
open "build/Duo More Thing.app" --args --preview           # play the animation after 1.5 s
"./build/Duo More Thing.app/Contents/MacOS/DuoMoreThing" --hold 0.55        # pin effect strength
"./build/Duo More Thing.app/Contents/MacOS/DuoMoreThing" --render-test ./out [image.png]   # 6 PNG frames
```

## How it works

`Sources/LidAngleSensor.swift`
: Lid-angle sensor. IOKit HID, **feature report** (not input report):
  VendorID `0x05AC`, ProductID `0x8104`, UsagePage `0x20`, Usage `0x8A`,
  reportID 1 → 3 bytes `[0x01, lo, hi]`, angle = little-endian `UInt16` in
  degrees. Present on MacBook Pro 16" 2019 and later. Verified on a
  MacBook Pro 14" M2 Pro.

`Sources/ScreenSource.swift`
: Screen capture via `SCScreenshotManager`. The frame is taken while
  “arming” — `armLead` degrees before the effect starts, while the overlay is
  still hidden, so the app never photographs itself. Fallback without
  permission: the wallpaper.

`Sources/EnvironmentSource.swift`
: One-shot FaceTime still of the room. On-device person segmentation fills the
  hole from the surrounding background; the result is blurred and used as the
  space behind the panel. No camera: blurred desktop wallpaper.

`Sources/OverlayController.swift`
: Full-screen borderless window at `CGShieldingWindowLevel` (above the menu
  bar and Dock), mouse-transparent. Public APIs cannot blur the real system
  UI, so a frozen frame is drawn on top of it.

`Shaders/Fold.metal` + `Sources/FoldRenderer.swift`
: The frame is a quad rotated around the bottom edge and projected in
  perspective. The projection is chosen so that at strength 0 the panel
  matches the screen pixel for pixel, then recedes into the space behind it.
  Variable blur is a Gaussian mip pyramid (`MPSImageGaussianPyramid`) plus
  explicit-LOD sampling: `n = mix(s^hingeCurve, s^topCurve, d^shape)` —
  two independent curves for the far edge and the hinge edge. Panel rims
  fade to the background via premultiplied alpha.

`Sources/FoldController.swift`
: Angle → strength → smoothing → overlay. Plus the still-lid safety.

`Sources/SettingsPanel.swift`
: SwiftUI + Liquid Glass, live offscreen preview of the effect.

## Limitations

- The effect is drawn over a frozen frame: while it runs, the UI is not live.
  That is the point of the animation.
- macOS will not draw the overlay on the lock screen — the unfold after sleep
  only plays if the system has not locked yet.
- Built-in display only.
