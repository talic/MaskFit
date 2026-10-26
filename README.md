# MaskFit

An iPhone app that measures your face with the Face ID (TrueDepth) camera and tells you how much to scale a
3D-printable mask, such as one from MakerWorld, in Bambu Studio.

Early prototype.

## How it works

1. **Sweep scan.** You turn your head slowly in a circle while a Face ID-style ring fills in. Each TrueDepth
   depth map (640×480, about 15 per second) is snapped onto ARKit's face mesh by rigid ICP, because ARKit's head
   pose is a few millimetres and degrees off, differently at each angle. The frames are then merged into a
   1.5 mm point cloud, which is drawn live on your face.
2. **Measurements.** Five distances are found on the merged cloud, using standard anthropometric landmarks:

   | | Measurement | On the face |
   |---|---|---|
   | A | Eye spacing | Eyeball centre to eyeball centre |
   | B | Face width | Across the cheekbones (zygion) |
   | C | Face length | Nose bridge (sellion) to chin (menton) |
   | D | Nose length | Nose bridge to nose tip (pronasale) |
   | E | Nose depth | Nose tip in front of the cheeks |

   The scan ends once every value has settled (six estimates over 3 s within 0.6 mm).
3. **Sizing.** You pick the mask type and padding, then measure the same distance on the inside of the mask in Bambu Studio, and the app works out
   the scale percentage, including padding. It also flags masks made for different face proportions, nose
   clearance problems, and magnet and strap holes that will change size.

## Layout

| Path | What it is |
|---|---|
| `MaskFit/FaceMeasurer.swift` | Landmark geometry; pure Swift |
| `MaskFit/DepthFusion.swift` | Depth back-projection, point cloud, ICP registration; pure Swift |
| `MaskFit/SweepScanner.swift` | ARKit session, progress ring, live cloud |
| `MaskFit/MaskSizing.swift` | Scale advice: padding, check measurements, warnings; pure Swift |
| `MaskFit/ResultsView.swift` | Results screen with the lettered head and mask renders |
| `MaskFit/Capture.swift` | Development recorder that saves raw frames for replay on the Mac (remove before release) |
| `Check/` | Mac checks for the maths above, against a CC0 head with known measurements |
| `Tools/` | Blender scripts that make the test head data and the diagram renders |
| `web/` | Web page that measures a mask's STL or 3MF and downloads it scaled; `mask.js` is the geometry, `check.mjs` its check |
| `MaskFitClip` target | App Clip version; needs a paid Apple developer team |

## Build and run

You need Xcode 27 and an iPhone with Face ID; face tracking doesn't run in the Simulator.

1. Open `MaskFit.xcodeproj`, choose your team under **Signing & Capabilities** for the MaskFit target, and run.
2. From the command line instead (replace the device ID):

   ```bash
   xcodebuild -project MaskFit.xcodeproj -scheme MaskFit -configuration Release \
     -destination "id=<device UDID>" -allowProvisioningUpdates -allowProvisioningDeviceRegistration build
   ```

The App Clip isn't embedded in the app at the moment, because free Personal Teams can't sign App Clips.

To see the results screen without scanning, for example in the Simulator, launch with `-demoResults`. Add
`-demoScroll sizing`, `measure` or `tips` to open it scrolled to that section with sample mask measurements.

## Checks

```bash
swiftc -O MaskFit/FaceMeasurer.swift MaskFit/DepthFusion.swift MaskFit/MaskSizing.swift Check/main.swift -o /tmp/facecheck && /tmp/facecheck Check
```

This checks the landmarks on the test head and the fusion of synthetic depth maps rendered from 11 angles,
both within 3 mm. It also checks detection of mirrored depth maps and the mask-sizing advice.

Pass a folder of frames recorded on the phone (`Documents/capture`, copied off with
`xcrun devicectl device copy from`) to replay a real scan instead.

The test head is the realistic head from Blender's
[Human Base Meshes](https://www.blender.org/download/demo/) bundle (CC0).

## Web: size a mask from its STL or 3MF

The web page loads a mask's STL or 3MF and finds A–E on its inside. A 3MF is measured as it sits on
the plate, so any scale already set in Bambu Studio counts. The page uses the object with the most
triangles and skips Bambu's modifier and negative parts. Downloads are STL. It does that with the same landmark rules
`FaceMeasurer.swift` uses on the face, because the inside of a mask is a negative of a face. It then
shows the lines on the mask, works out the scale with the `MaskSizing.swift` rules, and downloads the
STL scaled. Everything runs in the browser and the file isn't uploaded. To get your measurements in,
tap **Copy measurements** in the app and paste on the page, or open it with `#a=64.3&b=144.5&…`.

```bash
python3 -m http.server 8765 --bind 127.0.0.1 --directory web
```

Then open http://localhost:8765. The check builds a mask from the test head (padded 4 mm, eye holes cut,
turned and shrunk to 80%) and expects to get the head's measurements back:

```bash
node web/check.mjs
```

`node web/check.mjs mask.stl` (or `mask.3mf`) prints what it finds on any mask. `web/mask.js` ports the sizing rules
from `MaskSizing.swift`, so a change to one needs the same change in the other.

## Licence

MaskFit is free for non-commercial use under the
[PolyForm Noncommercial License 1.0.0](LICENSE.md). You can use it, change it and share your changes for
any non-commercial purpose, as long as you keep the `Required Notice` line that credits the author.
Commercial use isn't allowed. For a commercial licence, contact [@talic](https://github.com/talic).
