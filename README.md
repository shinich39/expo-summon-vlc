# expo-summon-vlc

An Expo native module for VLC-backed video playback on iOS and Android. It provides native playback sessions, a React Native video view, playlists, Picture in Picture (PiP), track selection, and media inspection APIs. A session owns playback independently of the view displaying it.

This project is under development. Core playback and several PiP and playlist scenarios have been exercised on devices, but broader device and media-format verification remains necessary. See [Known issues](#known-issues).

## Requirements

- An Expo or React Native application with Expo modules configured.
- A custom development build or a standalone native build. Expo Go cannot load this module.
- iOS 16.4 or later for the included iOS pod, or an Android device supported by the host app and LibVLC. Android PiP requires Android 8.0 or later.
- Native dependencies are installed by the build: VLCKit 4.0.0a25 on iOS and `org.videolan.android:libvlc-all:3.7.7` on Android.

The example currently uses Expo SDK 57. Compatibility with other SDK versions has not been established. The module does not implement a web player.

## Installation

Install the package in your Expo app directly from GitHub:

```sh
npm install github:shinich39/expo-summon-vlc
```

To install a specific release or commit, append its tag or commit hash, for example `github:shinich39/expo-summon-vlc#<tag-or-commit>`. GitHub installations run the package's `prepare` script to build its TypeScript output.

For local package development, install the checkout's dependencies and build it before installing it in your app:

```sh
cd /path/to/expo-summon-vlc
npm install
npm run build

cd /path/to/your-app
npm install /absolute/path/to/expo-summon-vlc
```

Configure the plugin and, if your app needs iOS background audio or PiP, the audio background mode:

```json
{
  "expo": {
    "plugins": ["expo-summon-vlc"],
    "ios": {
      "infoPlist": {
        "UIBackgroundModes": ["audio"]
      }
    }
  }
}
```

The plugin enables Android PiP on the main activity and adds the required configuration-change flags. Existing native projects must apply equivalent settings to their activity or regenerate their native projects using Expo prebuild. The plugin does not add the iOS background mode automatically.

Build the native app after installing the module or changing native configuration:

```sh
npx expo run:ios
# or
npx expo run:android
```

Use a physical iOS device to validate PiP. Native projects using a scene lifecycle may require additional host configuration; the example contains an app-specific scene lifecycle plugin in [`example/plugins/withSceneLifecycle.js`](example/plugins/withSceneLifecycle.js).

## Basic playback

Create a session, load a URI, attach a `PlayerView`, and release the session when it is no longer needed. The following component handles a session created after the component has already unmounted as well as setup failures:

```tsx
import { useEffect, useState } from 'react';
import { Text, View } from 'react-native';
import Player, { PlayerView } from 'expo-summon-vlc';

export function VideoPlayer({ uri }: { uri: string }) {
  const [sessionId, setSessionId] = useState<string | null>(null);
  const [error, setError] = useState<string | null>(null);

  useEffect(() => {
    let disposed = false;
    let id: string | null = null;
    setSessionId(null);
    setError(null);

    const setup = async () => {
      id = await Player.createSession();
      if (disposed) return;
      await Player.load(id, uri);
      if (disposed) return;
      setSessionId(id);
      await Player.play(id);
    };

    const finished = setup().catch((reason: unknown) => {
      if (!disposed) setError(String(reason));
    });

    return () => {
      disposed = true;
      void finished.then(async () => {
        if (id) await Player.release(id);
      }).catch((reason: unknown) => console.warn('Release failed:', reason));
    };
  }, [uri]);

  return (
    <View>
      {sessionId && (
        <PlayerView
          sessionId={sessionId}
          resizeMode="contain"
          style={{ width: '100%', aspectRatio: 16 / 9 }}
        />
      )}
      {error && <Text>{error}</Text>}
    </View>
  );
}
```

`load` replaces the current media and clears the playlist. Playback commands are asynchronous and can reject; a resolved command does not mean that media has finished buffering or a video frame has been displayed. `release` is asynchronous as well. Do not use a released session ID.

`PlayerView` accepts `contain` (the default, preserving the whole frame), `cover` (cropping to fill), or `fill` (stretching). The application controls the inline view's layout. On iOS, pass `disableResizeAnimation` to disable implicit animations when the internal video layer changes bounds (default: `false`). This does not disable animations applied by the app to `PlayerView` or its parent, and has no effect on Android. PiP uses contain behavior and its window is controlled by the operating system.

```tsx
<PlayerView sessionId={sessionId} disableResizeAnimation style={styles.video} />
```

## Playback and seeking

```ts
await Player.pause(sessionId);
await Player.play(sessionId);
await Player.seekTo(sessionId, 30_000); // milliseconds
await Player.stop(sessionId);

await Player.setPlaybackRate(sessionId, 1.5); // requested range: 0.25–4
await Player.setVolume(sessionId, 0.5);       // session volume: 0–1
await Player.setMuted(sessionId, true);
await Player.setAudioDelay(sessionId, 100);   // milliseconds; positive delays audio
```

On iOS, seek precision can be selected per request:

```ts
await Player.seekTo(sessionId, 30_000, { precision: 'precise' });
// Use { precision: 'fast' } for faster, potentially less accurate seeking.
```

The position passed to `seekTo` is in milliseconds on both platforms. To seek using a fraction, multiply it by the media duration in milliseconds. The default on iOS is `fast`. Actual seek accuracy and latency depend on the media and VLC. Android uses its existing LibVLC 3 seek behavior; requesting `precise` rejects on Android. For portable code, omit the option on Android or branch on `Platform.OS`.

Playback rate is a request and the effective rate can depend on the media. Volume is independent of device volume; muting preserves the configured session volume. Audio delay accepts values from -10,000 to 10,000 ms and is reapplied on media changes. Check `audioDelayApplied` in the playback status to see whether VLC accepted it.

## Playlists

Provide unique, nonempty IDs when the app needs to manage individual items. Setting a playlist prepares the list; select an item to start playback.

```ts
await Player.setPlaylistItems(sessionId, [
  { id: 'one', uri: firstUri, title: 'First video' },
  { id: 'two', uri: secondUri, title: 'Second video' },
]);
await Player.selectItem(sessionId, 'one');

await Player.next(sessionId);
await Player.previous(sessionId);
await Player.setRepeatMode(sessionId, 'all'); // 'off' | 'one' | 'all'
await Player.setShuffleEnabled(sessionId, true);

await Player.addItem(sessionId, { id: 'three', uri: thirdUri });
await Player.insertItem(sessionId, 1, { id: 'inserted', uri: fourthUri });
await Player.moveItem(sessionId, 0, 1);
await Player.removeItem(sessionId, 'three');
const items = await Player.getPlaylist(sessionId);
const current = await Player.getCurrentItem(sessionId);
await Player.clearPlaylist(sessionId);
```

`setPlaylist(sessionId, uris)` is also available and generates item IDs; `selectPlaylistItem(sessionId, index)` selects by index. Playlist items do not support VLC options. Removing the current item or clearing the list stops playback. On iOS, editing can be rejected during an active transition.

On iOS, playlist transitions default to a 10,000 ms timeout. Set a value of at least 1,000 ms for subsequent transitions:

```ts
await Player.setTransitionTimeout(sessionId, 5000);
```

Changing the timeout does not alter an ongoing transition. Android does not use this timeout and rejects this API. During an iOS selection, the native list temporarily contains only the requested item to prevent automatic playback of another item before the selection succeeds.

Repeat-one applies to automatic playback, while manual next and previous use playlist navigation. Shuffle keeps navigation history. `setFailurePolicy(sessionId, 'skip')` attempts another eligible item after a playback error; the default is `'stop'`. A run of consecutive failures is bounded so that a repeat-all list of failing items does not loop indefinitely.

## Playback status and events

Use `getPlaybackStatus` for a native snapshot and subscribe to events for changes. Filter by session because event listeners receive events from the module:

```ts
const progress = Player.addListener('onPlaybackProgress', event => {
  if (event.sessionId !== sessionId) return;
  console.log(event.positionMillis, event.durationMillis);
});
const states = Player.addListener('onPlaybackStateChange', event => {
  if (event.sessionId !== sessionId) return;
  console.log(event.state, event.currentItemId, event.sequence);
});
const errors = Player.addListener('onPlaybackError', event => {
  if (event.sessionId !== sessionId) return;
  console.warn(event.code, event.message);
});

const status = await Player.getPlaybackStatus(sessionId);
// When the listeners are no longer needed:
progress.remove();
states.remove();
errors.remove();
```

Progress updates are checked at approximately 100 ms intervals while playing or paused and emitted when position or duration changes. Timing is not guaranteed, especially when JavaScript is suspended. Progress events include `mediaRevision`, item identity and a sequence number: reject events for an old item or revision and older sequences for the same revision. Refresh the status after returning to the foreground or when receiving a state change.

State events are snapshots and may not include every transient VLC state. An error event follows its matching error-state event with the same sequence. `PLAYBACK_FAILED` and `TRANSITION_FAILED` are generic playback errors; they do not identify a specific codec or network cause. Command errors are reported separately through rejected promises.

## Audio and subtitle tracks

Track identifiers belong to a snapshot and are valid only for its revision. Refresh after media changes and after selection updates:

```ts
const tracks = await Player.getTracks(sessionId);
const subtitle = tracks.subtitles[0];
if (subtitle) {
  await Player.selectTrack(sessionId, 'subtitle', subtitle.id, tracks.revision);
}
// Disable subtitles with the current revision:
await Player.selectTrack(sessionId, 'subtitle', null, tracks.revision);
```

Use `'audio'` to select an audio track. `onTracksChanged` notifies the app to fetch a fresh snapshot; selection is asynchronous. Audio tracks cannot be disabled through `selectTrack`.

Subtitle preferences may be applied when creating a new session:

```ts
const sessionId = await Player.createSessionWithSubtitleStyle({
  fontScale: 1.5,
  textColor: 0xffff00, // optional RGB
  backgroundColor: 0x000000,
  backgroundOpacity: 160,
  outlineColor: 0x000000,
  outlineWidth: 4,
  bottomMargin: 30,
  alignment: 1, // -1 auto, 0 center, 1 left, 2 right
});
```

Alignment is applied when the session is created to text subtitles handled by VLC’s text subtitle decoder; other subtitle formats may ignore it. Text color is an optional RGB preference and may be overridden by the subtitle format. Subtitle formats with embedded styling and bitmap subtitles may override or ignore preferences. A styled session creates its own VLC instance. `getSubtitleStyleCapabilities()` reports supported operations; `setSubtitleFontScale(sessionId, scale)` changes font scale on iOS only, while other style changes require a new session.

## Picture in Picture

Start playback and check support before requesting PiP:

```ts
const subscription = Player.addListener('onPictureInPictureStateChange', event => {
  if (event.sessionId === sessionId) console.log(event.active, event.reason);
});

const pip = await Player.getPictureInPictureState(sessionId);
if (pip.supported) await Player.startPictureInPicture(sessionId);

// Later, request exit and observe the state event for completion:
await Player.stopPictureInPicture(sessionId);
// When no longer needed: subscription.remove();
```

A successful start or stop request does not guarantee the system has completed the transition. `eventsSupported` and `stopSupported` report native capabilities, not a guarantee that an OS request will succeed. Android stop requests return the activity to the foreground. Android event delivery depends on the host activity supporting AndroidX PiP mode change callbacks; otherwise query PiP state explicitly.

On Android the activity enters PiP and the app is responsible for its PiP layout. The example hides its controls and lets the video fill the available activity. The OS controls window size; the module requests an aspect ratio based on the current video. On iOS the session owns the PiP controller and sample-buffer output. Its memory-backed frame output caps the long side at 1280 pixels and can cost more CPU than a native video output.

Android PiP provides 10-second rewind, play/pause, and 10-second forward actions when supported by the device. The system controls their placement and may limit the number displayed. Seeking is limited to the current item and is disabled when the media is not seekable.

For optional iOS Control Center and Android system media controls:

```ts
await Player.setControlCenterEnabled(sessionId, true);
// Disable it before another session takes ownership, or release this session.
await Player.setControlCenterEnabled(sessionId, false);
```

System media controls are off by default and support one session at a time. They publish the current title, duration and playback state and handle playback, playlist navigation and seeking when available. Android displays a media notification; its layout depends on the system. Audio interruptions and device route changes are handled independently of this option. Resumption depends on the interruption and system behavior; stopping another music app does not guarantee automatic resume.

Set custom artwork for the iOS Now Playing card or Android MediaSession and notification with a local image URI. Passing `null` clears the override. Without a custom image, iOS uses artwork exposed by VLCKit metadata when available; Android does not automatically extract audio album art.

```ts
await Player.setControlCenterArtwork(sessionId, { uri: localImageUri });
const frame = await Player.captureCurrentFrame(sessionId);
await Player.setControlCenterArtwork(sessionId, { uri: frame.uri });
// The app owns generated files and should remove them when no longer needed.
await Player.setControlCenterArtwork(sessionId, null);
```

`captureCurrentFrame` saves the latest decoded video frame as a temporary JPEG and returns its URI and dimensions. iOS captures the most recently decoded frame; Android captures the visible `PlayerView` surface and requires Android 8.0 or later. On Android, attach a visible `PlayerView` and wait for a video frame first. It is not available for audio-only playback or when the view is detached. The generated image file belongs to the caller. The same `{ uri }` input works with `setControlCenterArtwork` for extracted album art, captured frames, or a poster image.

To retain a session for background playback and reconnect while the app process remains alive, load media and enable background playback while the app is visible. This also enables system media controls:

```ts
await Player.setBackgroundPlaybackEnabled(sessionId, true);

// On a later app launch, reconnect to a still-running session if one exists.
const existingSessionId = await Player.getBackgroundSessionId();

// Disable background retention or release the session when it is no longer needed.
await Player.setBackgroundPlaybackEnabled(sessionId, false);
```

Android uses a media playback foreground service and displays a media notification. iOS requires the `audio` background mode described above. Both platforms retain the selected session across Expo module teardown and allow `getBackgroundSessionId()` to reconnect while the process remains alive. Explicit `stop`, `release`, disabling system media controls, or reaching the end of the playlist ends background retention. Re-enable it after a stop. Neither platform restores a session after process death or a force-stop. Android restricts starting foreground services from the background; enable it while the app is visible. Disabling background retention leaves system media controls enabled until explicitly disabled or the session is released.

Audio files can use the same session and playback APIs without mounting a `PlayerView`. The example includes an audio test that removes the video view before playing a configurable audio URL. Background audio on iOS requires the `audio` background mode described above.

## Inspect media and generate thumbnails

These operations do not require playback or a player session:

```ts
const metadata = await Player.inspectMedia('inspection-1', mediaUri, 15_000);
const thumbnail = await Player.generateThumbnail(
  'thumbnail-1', localFileUri, 1_000, 15_000
);
console.log(metadata, thumbnail.uri);

// While a job is pending, use its unique request ID:
// await Player.cancelMediaJob('thumbnail-1');
// Delete thumbnail.uri using your application's file API when finished.
```

Request IDs must be unique among pending jobs. Only one inspection or thumbnail job runs at a time; after cancellation or timeout, native cleanup can briefly leave the service busy. Timeouts must be 100–120,000 ms. Metadata accepts local file, HTTP and HTTPS URIs; thumbnails currently require local files. Thumbnails are temporary JPEG files owned by the caller. iOS uses AVFoundation and reports the selected frame time when available; Android uses `MediaMetadataRetriever` and does not report the actual frame time. Their codec support can differ from VLC.

Extract embedded album art from a local audio file with `extractAlbumArt`. It returns a temporary JPEG file URI and its dimensions, or `null` when the file has no embedded artwork. The caller owns and must delete the returned file. Android uses `MediaMetadataRetriever`; iOS uses VLCKit media metadata. Artwork format support depends on each platform parser and the media container/tag; there is no cross-platform format guarantee.

```ts
const albumArt = await Player.extractAlbumArt('album-art-1', localAudioUri, 15_000);
if (albumArt) console.log(albumArt.uri, albumArt.width, albumArt.height);
```

To check for audio and video tracks before playback, inspect the URI and examine its tracks:

```ts
try {
  const media = await Player.inspectMedia('track-inspection-1', mediaUri, 15_000);
  const hasVideo = media.tracks.some((track) => track.type === 'video');
  const hasAudio = media.tracks.some((track) => track.type === 'audio');

  // Mount PlayerView when hasVideo is true; audio-only playback needs no view.
  console.log({ hasVideo, hasAudio });
} catch (error) {
  // Inspection failed; the media type is unknown, not necessarily audio-only.
  console.error('Could not inspect media:', error);
}
```

Inspection is separate from playback. Network sources can take time or fail to parse, and a successful result with no recognized tracks does not establish that the media is audio-only. Inspect each playlist item as needed; `getTracks()` currently returns audio and subtitle tracks only.

## Running the example

The [`example/`](example/) app contains controls for playback, PiP, playlists, tracks, subtitle styling and media analysis. It downloads two sample videos once and creates local copies for playlist testing; subsequent loads reuse the files for the same URLs.

```sh
cd example
npm install
npx expo run:ios
# or
npx expo run:android
```

See the [example guide](example/README.md) for the test controls and the experimental iOS frame probe. Native changes require a new development build.

## Known issues

- iOS: A PiP stop request may leave PiP active when the app is in the background.
- PiP transitions, restoration, seeking and resource cleanup need broader device testing.
- Android: Precise seeking and live subtitle font scaling are not supported.
- Android: PiP state events depend on host activity support.
- Video rotation is not supported.
- Thumbnail generation requires a local file and may not support all VLC-playable formats.

## Acknowledgements

Special thanks to the following projects for their inspiration and contributions to the open-source community:

- [expo-libvlc-player](https://github.com/cornejobarraza/expo-libvlc-player)

## Third-Party Notices

This project uses the following unmodified third-party libraries.

### iOS

- Library: VLCKit
- Version: 4.0.0a25
- License: LGPL-2.1-or-later
- Source: https://code.videolan.org/videolan/VLCKit
- No changes to library's source code.

### Android

- Library: LibVLC (`org.videolan.android:libvlc-all`)
- Version: 3.7.7
- License: LGPL-2.1
- Source: https://code.videolan.org/videolan/libvlcjni
- No changes to library's source code.

See the [GNU LGPL 2.1 license](licenses/LGPL-2.1.txt) for the license terms.

## License

This project is licensed under the [MIT License](LICENSE).

VLCKit and LibVLC are third-party dependencies licensed under the LGPL. See [Third-Party Notices](THIRD_PARTY_NOTICES.md) for details.
