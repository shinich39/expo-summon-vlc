# iOS playback gate

This isolated UIKit app is a manual starting point for the iOS PiP feasibility
experiment. It is not included in the Expo module or the Expo example app and
does not implement PiP.

Run `pod install` in this directory, open `PlaybackGate.xcworkspace` in Xcode,
and select a development team and bundle identifier for a physical device.
Select two local video files using the app's file picker, then use the play,
pause and switch controls. The picker imports copies into the app's sandbox.

On a physical device, check local playback, pause/resume and file switching while
the same controller, player and video view remain alive. Record the device, OS,
fixture details and observations in `docs/ios-pip-feasibility.md`. Continue to
the PiP steps only after a supported frame-and-timestamp path is established.
The app has not yet been compiled or run.
