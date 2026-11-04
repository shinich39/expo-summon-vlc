import type { StyleProp, ViewStyle } from 'react-native';

/** contain preserves the full frame, cover crops it, and fill stretches it. */
export type VideoResizeMode = 'contain' | 'cover' | 'fill';

export type PlayerViewProps = {
  sessionId: string;
  /** Defaults to contain. */
  resizeMode?: VideoResizeMode;
  /** iOS: disable implicit animations when the internal video layer changes bounds. Defaults to false. */
  disableResizeAnimation?: boolean;
  style?: StyleProp<ViewStyle>;
};

/** iOS seek preference. Android supports only its default seek behavior. */
export type SeekOptions = { precision?: 'fast' | 'precise' };

/** States reported by the current native implementations. */
export type PlaybackState = 'idle' | 'preparing' | 'buffering' | 'playing' | 'paused' | 'ended' | 'stopped' | 'error' | 'unknown';

export type PlaybackErrorCode = 'PLAYBACK_FAILED' | 'TRANSITION_FAILED';

export type PlaybackFailure = {
  code: PlaybackErrorCode;
  message: string;
};

export type PlaybackStatus = {
  state: PlaybackState;
  currentIndex: number;
  currentItemId: string | null;
  /** Changes when the native playback item is replaced. */
  mediaRevision: string;
  /** Most recently emitted progress sequence for this session. */
  progressSequence: number;
  /** Most recently emitted state-event sequence for this session. */
  eventSequence: number;
  error: PlaybackFailure | null;
  positionMillis: number;
  durationMillis: number;
  isSeekable: boolean;
  /** Requested playback rate; actual speed may depend on the media. */
  playbackRate: number;
  /** Session volume from 0 to 1, independent of mute and device volume. */
  volume: number;
  muted: boolean;
  /** Requested audio offset in milliseconds. Positive delays audio. */
  audioDelayMillis: number;
  /** Whether VLC accepted the requested offset for the current media. */
  audioDelayApplied: boolean;
  repeatMode: RepeatMode;
  shuffleEnabled: boolean;
  failurePolicy: PlaybackFailurePolicy;
  canNext: boolean;
  canPrevious: boolean;
};

export type RepeatMode = 'off' | 'one' | 'all';
/** Defaults to stop. Skip attempts each item at most once per consecutive failure run. */
export type PlaybackFailurePolicy = 'stop' | 'skip';

export type PlaylistItem = {
  /** Unique within the playlist. */
  id: string;
  uri: string;
  title?: string;
};

export type PlaybackTrack = {
  /** Opaque identifier, valid only for the accompanying revision. */
  id: string;
  name: string | null;
  language: string | null;
  selected: boolean;
};

export type PlaybackTracks = {
  revision: string;
  currentIndex: number;
  audio: PlaybackTrack[];
  subtitles: PlaybackTrack[];
};

export type PlaybackTrackType = 'audio' | 'subtitle';

/** VLC text subtitle preferences applied when a new session is created. */
export type SubtitleStyle = {
  /** Relative to VLC's default, from 0.5 to 3. */
  fontScale: number;
  /** Optional 24-bit RGB text color; subtitle styles may override it. */
  textColor?: number;
  /** 24-bit RGB color, e.g. 0xffffff. */
  backgroundColor: number;
  /** Background opacity from 0 to 255. */
  backgroundOpacity: number;
  outlineColor: number;
  /** VLC outline thickness from 0 to 5. */
  outlineWidth: number;
  /** Bottom margin in VLC output pixels, from 0 to 500. */
  bottomMargin: number;
  /** Text alignment: -1 auto (default), 0 center, 1 left, 2 right. */
  alignment?: -1 | 0 | 1 | 2;
};

export type SubtitleStyleCapabilities = {
  creationStyle: boolean;
  liveFontScale: boolean;
};

export type PlaybackStateChange = {
  sessionId: string;
  currentIndex: number;
  currentItemId: string | null;
  sequence: number;
  state: PlaybackState;
};

/** A native playback snapshot emitted at most ten times per second. */
export type PlaybackProgress = {
  sessionId: string;
  currentIndex: number;
  currentItemId: string | null;
  mediaRevision: string;
  sequence: number;
  positionMillis: number;
  durationMillis: number;
};

/** Emitted after the matching error state event, with the same sequence. */
export type PlaybackErrorEvent = PlaybackFailure & {
  sessionId: string;
  currentIndex: number;
  currentItemId: string | null;
  sequence: number;
};

export type PictureInPictureState = {
  supported: boolean;
  active: boolean;
  reason: string | null;
  /** Whether native mode changes can be observed for this activity. */
  eventsSupported: boolean;
  /** Whether this platform can request PiP to close. */
  stopSupported: boolean;
};

export type PictureInPictureStateChange = PictureInPictureState & { sessionId: string };
export type PictureInPictureExitTestEvent = {
  sessionId: string;
  stage: 'requested' | 'will_stop' | 'not_active' | 'failed' | 'still_active';
  message: string | null;
};

export type MediaTrack = {
  type: 'video' | 'audio' | 'text' | 'unknown';
  codec?: string;
  id?: number;
  bitrate?: number;
  language?: string;
  width?: number;
  height?: number;
  frameRate?: number;
  channels?: number;
  sampleRate?: number;
};

export type MediaInspection = {
  durationMillis: number | null;
  title: string | null;
  tracks: MediaTrack[];
};

export type MediaThumbnail = {
  uri: string;
  requestedPositionMillis: number;
  /** iOS reports the selected frame time; Android does not expose it. */
  actualPositionMillis: number | null;
  width: number;
  height: number;
};

export type AlbumArt = {
  /** Temporary JPEG file owned by the caller; delete it when no longer needed. */
  uri: string;
  width: number;
  height: number;
};
