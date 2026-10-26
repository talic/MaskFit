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
