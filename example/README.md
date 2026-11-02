# Expo playback preview

This example exercises the initial shared session and video view API on iOS and
Android. From this directory install the existing dependencies and run the
normal Expo native commands (`npx expo run:ios` or `npx expo run:android`). A
development build is required; Expo Go cannot load this native module. The iOS
and Android native dependency changes require a fresh native build.
The example configures Expo's scene lifecycle integration for iOS 27 through
`plugins/withSceneLifecycle.js`; its generated iOS app must be rebuilt after
this configuration changes.

Enter two HTTP(S) video URLs and tap **Load**. The app downloads
them into its document directory and creates three local copies, registering
five files with the native player. Preparing again with the same URLs reuses the
saved files. Changing the URLs prepares a separate set. Uninstalling the app
removes its files.

Use **Release session** and **Create session** to exercise session cleanup.
After creating a new session, tap **Load** again; the downloaded
files are reused. The displayed counts record successful operations in this
screen, not live native instances or freed memory. Repeat playback, PiP and
release while watching memory over several cycles. On iOS, releasing an active
PiP session first requests that PiP stop, then releases the player. If the
system does not stop PiP, release reports a timeout and can be retried.
If the underlying VLC cleanup itself times out, the session is removed from the
screen but new iOS sessions are rejected until that cleanup actually finishes;
this avoids accumulating players whose native resources are still in use.

The **Pre-playback media analysis** controls work without starting playback.
**Inspect metadata** analyzes the first URL with VLC, or the first
saved file after **Save files for analysis**. Saving reuses the same local cache
as the playlist. Enter a timestamp in milliseconds and choose **Generate
thumbnail**; the example displays the temporary image and deletes its previous
thumbnail when replaced or the screen is destroyed. Use **Cancel analysis** to
cancel a pending native operation.

The underlying TypeScript APIs accept a caller-generated, unique request ID:

```ts
const metadata = await Player.inspectMedia('metadata-1', uri, 15000);
const thumbnail = await Player.generateThumbnail('thumb-1', localFileUri, 1000, 15000);
// Delete thumbnail.uri with the application's file API when no longer needed.
// While a request is pending: await Player.cancelMediaJob(requestId);
```

Only one metadata or thumbnail job is allowed at once. Timeout must be 100 to
120000 ms. Metadata accepts file, HTTP and HTTPS URIs; thumbnail generation
currently accepts local file URIs only. Thumbnails use AVFoundation on iOS and
MediaMetadataRetriever on Android, so codec support can differ from VLC and
extraction can fail for a file VLC can play. Android returns a nearby frame and
does not report its actual timestamp. After cancellation or timeout, a native
operation may still be finishing; subsequent requests can briefly return busy.
These APIs and their codec coverage still require device verification.

The default first clip is landscape (1920×1080, 16:9); the default second clip
is portrait (720×1280, 9:16), as measured from the current files. The playlist
alternates between the two sources, including their copies.

The playlist controls can select items by ID, add or insert a copy of the
first item, move or remove items, and clear the list. Removing the current item
or clearing the list stops playback; select an item to resume. On iOS, edits
are rejected while a file transition is still in progress. Shuffle history is
preserved for items that remain in the list. These operations and PiP playback
while editing still require device verification.

```ts
await Player.setPlaylistItems(sessionId, [
  { id: 'first', uri: firstUri, title: 'First video' },
  { id: 'second', uri: firstUri, title: 'Same URI, different item' },
]);
await Player.selectItem(sessionId, 'first');
await Player.addItem(sessionId, { id: 'third', uri: secondUri });
await Player.insertItem(sessionId, 1, { id: 'inserted', uri: secondUri });
await Player.moveItem(sessionId, 0, 1);
await Player.removeItem(sessionId, 'third');
const items = await Player.getPlaylist(sessionId);
const current = await Player.getCurrentItem(sessionId);
await Player.clearPlaylist(sessionId);
```

The original `setPlaylist(sessionId, uris)` API remains available and assigns
generated IDs. Item IDs must be nonempty and unique within the playlist;
VLC options are not supported by these item APIs yet.

Playback status includes `currentItemId`, `eventSequence`, and `error`.

`onPlaybackProgress` emits a snapshot at most ten times per second while
playing or paused and the position or duration changes. It includes the
session, item, `mediaRevision`, `sequence`, position and duration. Compare the
revision and item identity with `getPlaybackStatus()` before using a progress
event; discard earlier sequence numbers for the same session. Events can be
delayed while JavaScript is suspended. Query status again when resuming.
The example uses these events for its seek bar and refreshes full status on
state changes and at a one-second fallback interval.

```ts
const progress = Player.addListener('onPlaybackProgress', event => {
  if (event.sessionId === sessionId) console.log(event.positionMillis, event.durationMillis);
});
// When no longer needed: progress.remove();
```

Use **Test playback error** to replace the current playlist with a deliberately
missing local file. The error event is displayed on screen and logged to the JS
console. A failed command is shown separately. Tap **Load** to restore the
normal example playlist. iOS may take several seconds to report a transition
failure.

`setFailurePolicy(sessionId, 'stop' | 'skip')` selects what happens after a
playback error; `stop` is the default. Skip tries the next eligible playlist
item, bypasses repeat-one for a failed item, and stops once no unfailed
candidate remains. Repeat-all may wrap; shuffle follows its remaining order.
The failure history resets after an item has played for at least one second,
or when the user explicitly selects an item. `getPlaybackStatus` reports the
current policy. Edits are rejected while an item transition is in progress.
On iOS, skip with repeat-all uses explicit repeat at the end of successful
playback; native list looping is disabled to avoid repeated failed media.

Use **Load** once, then **Test skip failure** to play a missing file followed by
a valid file. **Test all fail** uses two missing files with repeat-all; it
should stop on an error after trying both instead of cycling indefinitely.

Subscribe to state and playback errors as follows:

```ts
const states = Player.addListener('onPlaybackStateChange', event => {
  if (event.sessionId === sessionId) console.log(event.sequence, event.currentItemId, event.state);
});
const errors = Player.addListener('onPlaybackError', event => {
  if (event.sessionId === sessionId) console.log(event.code, event.message);
});
// When no longer needed: states.remove(); errors.remove();
```

Sequence numbers increase per session when a distinct state or item is
reported. An error event follows its matching state event with the same sequence.
The events are snapshots of native state, not a guarantee that every transient
VLC state will be observed. `PLAYBACK_FAILED` is a generic player error;
`TRANSITION_FAILED` identifies an iOS playlist transition failure. Neither
reports a specific network or codec cause. Command validation and operation
failures are still returned by rejected promises. `getPlaybackStatus` rejects
after release; it does not report a separate released state. The exposed state
union reflects states currently observable on each platform and does not claim
distinct `ready` or `seeking` states.

Use the **contain**, **cover**, and **fill** controls under the video to change
the `PlayerView`'s `resizeMode` during playback. `contain` shows the full frame
with possible black bars, `cover` fills the view and crops the frame, and `fill`
stretches the frame. The default is `contain`; changing it does not recreate the
session. The view's size is controlled by the app. PiP uses `contain` regardless
of this setting, and the chosen mode is restored when PiP ends. The operating
system controls the PiP window size. Verify these behaviors on devices.

```tsx
<PlayerView sessionId={sessionId} resizeMode="cover" style={styles.video} />
```

The controls below the video also adjust playback speed, session volume and
mute. These settings belong to the session and do not change device volume.
Volume is from 0 to 1 in 1% steps; muting preserves the chosen volume for
unmute. The requested rate is from 0.25 to 4, but VLC or the media can limit
the actual speed. `getPlaybackStatus` reports the requested settings.

```ts
await Player.setPlaybackRate(sessionId, 1.5);
await Player.setVolume(sessionId, 0.5);
await Player.setMuted(sessionId, true);
```

Audio delay can be adjusted while media is playing or paused. Positive values
delay audio; negative values move it earlier. The allowed range is -10000 to
10000 milliseconds. The session reapplies the requested delay when the media
changes; `getPlaybackStatus` reports both `audioDelayMillis` and whether VLC
accepted it for the current media in `audioDelayApplied`. Actual audio/video
synchronization depends on the media and output device.

```ts
await Player.setAudioDelay(sessionId, 100);
```

The first item starts after preparation. Use **Previous** and **Next** to inspect
transitions, including rapid successive requests. **Repeat** cycles through
off, one and all: one repeats the current item automatically, while all wraps
at the ends. Manual Next and Previous ignore repeat-one. **Shuffle** visits the
remaining items in random order; Previous follows the actual history and Next
after Previous follows that history forward. Enabling or disabling shuffle or
replacing the playlist resets the shuffle history. The most recent 1000 shuffle
history entries are retained. Repeat-all begins a new shuffled pass after the
current one; without repeat-all playback ends after the pass. The mode is owned
by the native session and Android PiP controls use the same order. iOS and
Android device verification is still required. The seek bar shows elapsed time and duration and supports
tapping or dragging to seek. Seeking while paused keeps playback paused; seeking
after the item has ended restarts it at the requested position. Progress uses native events, with full playback status refreshed on state changes and once per second; the transition history listens for native state events. Neither measures first-frame presentation.
This is an initial playlist and its transition and resource behavior still
requires broader verification.

On Android 8.0 or later, the **Enter Picture-in-Picture** button starts an
initial Activity-based PiP experiment for the attached video session. Test
entering PiP, automatic playlist advance and returning to the same screen.
The PiP aspect ratio follows the active video's dimensions, pixel aspect ratio,
and orientation when available, within Android's allowed PiP ratio range. The
previous window ratio is retained until the next video's track is available.
During a PiP item transition, a black placeholder covers the output until the
track ratio and resized output bounds agree. Android 12 and later use the
system's non-seamless resize transition to reduce resize artifacts. This does
not guarantee detection of the first decoded frame.
The app hides its controls while in PiP and exposes previous, play/pause and
next actions in the system PiP menu. Android may limit the number of actions.
UI restoration, PiP actions and background behavior still need device
validation.
The reported Android support indicates device support, not a guarantee that
activity configuration or current system policy allows entry. Entry failures
are reported separately. The included config plugin sets the required Activity
manifest attributes during Expo prebuild. Existing native projects must apply
the equivalent settings or be regenerated.

`stopPictureInPicture(sessionId)` requests exit from PiP. On Android it brings
the existing activity to the foreground; on iOS it asks AVKit to close the PiP
window. The promise confirms the request, not completion. Subscribe to
`onPictureInPictureStateChange` to observe the actual start, stop, or iOS start
failure. `getPictureInPictureState` reports `eventsSupported` and
`stopSupported`; Android event support requires the host activity to implement
AndroidX's PiP mode change provider. A system policy can still reject or delay
an exit request. Android discovers that provider at runtime; when it is absent
or listener registration fails, `eventsSupported` is false and callers can use
`getPictureInPictureState` instead. On iOS, stopping PiP without an active app view pauses playback
under the existing close policy.

Use **Test PiP exit (5s)** to request PiP and then request exit after five
seconds. The timer is scheduled natively. The diagnostic reports when the exit
request is made, when it fails, and whether PiP remains active three seconds
later; events appear on screen and in the JS console when JS is running. The OS
can still delay execution or deny bringing an activity to the foreground.
On iOS, **Test PiP exit (1s)** also helps compare a quick request with the
five-second background request. The `will_stop` diagnostic is an AVKit delegate
callback; it can also appear when the user closes PiP during the test.
On one tested iOS device, stopping succeeded while the app was foregrounded but
an active PiP window remained open after a background stop request. The cause
and a reliable background remedy have not been established. `stopSupported`
indicates the request API is available; it does not guarantee that PiP closes.

```ts
const subscription = Player.addListener('onPictureInPictureStateChange', event => {
  if (event.sessionId === sessionId) console.log(event.active, event.reason);
});
await Player.startPictureInPicture(sessionId);
// Later: await Player.stopPictureInPicture(sessionId);
// When no longer needed: subscription.remove();
```

iOS PiP for the normal playlist uses the same VLC player and video output as
the inline view. Prepare the playlist, start playback and tap **Enter
Picture-in-Picture**. Verify audio, video, pause/resume, automatic item changes
and return to the same session on a physical device. The normal playlist uses a session-owned sample-buffer display layer and PiP
controller with LibVLC frame callbacks. Verify playback, seeking, playlist
transitions and release on a physical device. This memory output copies frames
and caps the long side at 1280 pixels, so it may use more CPU than native video
output. The session uses LibVLC's public list-player and video callback APIs.

On iOS, **Control Center: Off/On** enables or disables system media controls for
the current session. The default is off. It publishes the VLC title (or filename),
artist when available, duration, position and playback state, and handles play,
pause, previous, next and position changes. Only one session can own the controls
at a time. Disabling the option or releasing its session removes its handlers.
From JavaScript use `await Player.setControlCenterEnabled(sessionId, true)` and
pass `false` to turn it off. This option is iOS-only; enabling it on Android
rejects the request.

The normal player requests audio focus on Android and uses the playback audio
session on iOS. Transient interruptions pause playback and may resume it when
the system permits; a user pause, stop, or output-device disconnect cancels
automatic resume. Permanent Android focus loss pauses playback. PiP controls
operate on the same session. On Android 15 and later, focus requests can fail
when the app is neither the foreground app nor running a foreground service;
this example does not provide a playback foreground service. Verify calls,
other media apps, headset disconnect and PiP on real devices.

Use **Refresh tracks** while media is playing or paused to inspect and select
audio and subtitle tracks. Choose **Subtitles off** to disable subtitles. The
list is a snapshot; refresh it after a file change. Selection changes update
the visible list after the native player reports them.
The default playlist videos do not contain separate subtitle streams. Use
Open **Show previous tests** and use **Start subtitle test** to create a styled
session, start the bundled MP4, select an English subtitle and repeat the video.
The on-screen text changes at 5 and 10 seconds. The asset is cached locally
after its first download from the development server. Track
names and languages can be unavailable. iOS sample-buffer subtitle rendering
and both platforms' selection behavior still require device verification.

From JavaScript, call `getTracks(sessionId)` and pass its `revision` and a track
ID to `selectTrack(sessionId, 'audio' | 'subtitle', id, revision)`. Pass `null`
as the subtitle ID to turn subtitles off. IDs and revisions are valid for the
current media only. Selection is asynchronous; listen for `onTracksChanged`
and refresh the list to observe the selected state.

Subtitle style preferences are supplied when creating a session:

```ts
const sessionId = await Player.createSessionWithSubtitleStyle({
  fontScale: 1.5,
  backgroundColor: 0x000000,
  backgroundOpacity: 160,
  outlineColor: 0x000000,
  outlineWidth: 4,
  bottomMargin: 30,
});
```

The example exposes the same settings after releasing the current session.
Colors are 24-bit RGB integers; opacity is 0–255, outline width 0–5, bottom
margin 0–500 output pixels, and font scale 0.5–3. VLC 3 on Android approximates
font scaling with a relative-size option. iOS VLC 4 also exposes
`setSubtitleFontScale(sessionId, scale)` for changing size during playback;
Android rejects that operation. Check `getSubtitleStyleCapabilities()` before
using it. Other style settings require a new session on both platforms. Each
styled session creates its own VLC instance, which can increase memory usage.
Embedded subtitle styling and bitmap subtitles may override or ignore these
preferences; actual output and PiP remain subject to device verification.
Text color follows VLC and the subtitle's embedded style; it cannot be set
through this API.

On iOS, prepare the local playlist and use **Start iOS frame probe** to test
an independent muted LibVLC decoder; it pauses the normal player and displays
the number of frame callbacks and a sample-buffer preview. **Start experimental
PiP** attempts to open that separate preview in system PiP. Use the probe's
play/replay button if the short clip has already ended, and stop PiP before
stopping the probe. This experiment is muted, uses a fixed memory output size,
may drop frames, and does not carry the playlist session into PiP. PiP entry,
controls and restoration still require physical-device verification.
Native changes require a new development build; the iOS app declares the audio
background mode in its Expo configuration.
