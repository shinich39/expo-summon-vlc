import { NativeModule, requireNativeModule } from 'expo';
import type { MediaInspection, MediaThumbnail, PictureInPictureExitTestEvent, PictureInPictureState, PictureInPictureStateChange, PlaybackErrorEvent, PlaybackFailurePolicy, PlaybackProgress, PlaybackStateChange, PlaybackStatus, PlaybackTracks, PlaybackTrackType, PlaylistItem, RepeatMode, SeekOptions, SubtitleStyle, SubtitleStyleCapabilities } from './ExpoSummonVlc.types';

declare class ExpoSummonVlcModule extends NativeModule<{
  onPlaybackStateChange: (event: PlaybackStateChange) => void;
  onPlaybackProgress: (event: PlaybackProgress) => void;
  onPlaybackError: (event: PlaybackErrorEvent) => void;
  onTracksChanged: (event: { sessionId: string; revision: string }) => void;
  onPictureInPictureStateChange: (event: PictureInPictureStateChange) => void;
  onPictureInPictureExitTest: (event: PictureInPictureExitTestEvent) => void;
}> {
  createSession(): Promise<string>;
  /** Creates a separate VLC instance. Styles may be overridden by the subtitle format. */
  createSessionWithSubtitleStyle(style: SubtitleStyle): Promise<string>;
  getSubtitleStyleCapabilities(): Promise<SubtitleStyleCapabilities>;
  /** Live font scaling is supported on iOS only; use a new styled session on Android. */
  setSubtitleFontScale(sessionId: string, scale: number): Promise<void>;
  load(sessionId: string, uri: string): Promise<void>;
  setPlaylist(sessionId: string, uris: string[]): Promise<void>;
  setPlaylistItems(sessionId: string, items: PlaylistItem[]): Promise<void>;
  getPlaylist(sessionId: string): Promise<PlaylistItem[]>;
  getCurrentItem(sessionId: string): Promise<PlaylistItem | null>;
  addItem(sessionId: string, item: PlaylistItem): Promise<void>;
  insertItem(sessionId: string, index: number, item: PlaylistItem): Promise<void>;
  /** Removing the current item stops playback. */
  removeItem(sessionId: string, itemId: string): Promise<void>;
  moveItem(sessionId: string, fromIndex: number, toIndex: number): Promise<void>;
  clearPlaylist(sessionId: string): Promise<void>;
  selectItem(sessionId: string, itemId: string): Promise<void>;
  selectPlaylistItem(sessionId: string, index: number): Promise<void>;
  next(sessionId: string): Promise<void>;
  previous(sessionId: string): Promise<void>;
  setRepeatMode(sessionId: string, mode: RepeatMode): Promise<void>;
  setShuffleEnabled(sessionId: string, enabled: boolean): Promise<void>;
  setFailurePolicy(sessionId: string, policy: PlaybackFailurePolicy): Promise<void>;
  /** iOS only. Applies to subsequent playlist transitions; minimum 1000 ms, default 10000 ms. */
  setTransitionTimeout(sessionId: string, timeoutMillis: number): Promise<void>;
  /** Disabled by default. Only one session can own the system media controls. */
  setControlCenterEnabled(sessionId: string, enabled: boolean): Promise<void>;
  /** Android: enable while the app is foregrounded, after loading media and enabling system controls. */
  setBackgroundPlaybackEnabled(sessionId: string, enabled: boolean): Promise<void>;
  /** Returns the retained Android session while background playback is enabled. */
  getBackgroundSessionId(): Promise<string | null>;
  getPlaybackStatus(sessionId: string): Promise<PlaybackStatus>;
  /** Track lists are snapshots. Refresh after a media transition. */
  getTracks(sessionId: string): Promise<PlaybackTracks>;
  /** Pass null to disable subtitles; audio tracks cannot be disabled here. */
  selectTrack(sessionId: string, type: PlaybackTrackType, id: string | null, revision: string): Promise<void>;
  /** iOS defaults to fast. Android uses its default seek and rejects precise. */
  seekTo(sessionId: string, positionMillis: number, options?: SeekOptions): Promise<void>;
  /** Requested rate from 0.25 to 4; support depends on the media. */
  setPlaybackRate(sessionId: string, rate: number): Promise<void>;
  /** Session software volume from 0 to 1. */
  setVolume(sessionId: string, volume: number): Promise<void>;
  setMuted(sessionId: string, muted: boolean): Promise<void>;
  /** Audio offset from -10000 to 10000 ms; positive values delay audio. */
  setAudioDelay(sessionId: string, delayMillis: number): Promise<void>;
  getPictureInPictureState(sessionId: string): Promise<PictureInPictureState>;
  startPictureInPicture(sessionId: string): Promise<void>;
  /** Requests exit; observe the PiP state event for completion. Android returns the activity to the foreground. */
  stopPictureInPicture(sessionId: string): Promise<void>;
  /** Example diagnostic: starts PiP and schedules a native exit request. */
  startPictureInPictureExitTest(sessionId: string, delayMillis: number): Promise<void>;
  /** Experimental iOS-only muted, independent player and PiP probe. */
  startFrameProbe(uri: string): Promise<void>;
  getFrameProbeStatus(): Promise<{ running: boolean; frames: number }>;
  stopFrameProbe(): Promise<void>;
  setFrameProbePlaying(playing: boolean): Promise<void>;
  getFrameProbePictureInPictureState(): Promise<{ supported: boolean; possible: boolean; active: boolean; starting: boolean; error: string | null }>;
  startFrameProbePictureInPicture(): Promise<void>;
  stopFrameProbePictureInPicture(): Promise<void>;
  /** requestId must be unique among pending inspection and thumbnail jobs. */
  inspectMedia(requestId: string, uri: string, timeoutMillis: number): Promise<MediaInspection>;
  /** Local files only. Output is a temporary JPEG; the caller owns its cleanup. */
  generateThumbnail(requestId: string, uri: string, positionMillis: number, timeoutMillis: number): Promise<MediaThumbnail>;
  cancelMediaJob(requestId: string): Promise<boolean>;
  play(sessionId: string): Promise<void>;
  pause(sessionId: string): Promise<void>;
  stop(sessionId: string): Promise<void>;
  release(sessionId: string): Promise<void>;
}

export default requireNativeModule<ExpoSummonVlcModule>('ExpoSummonVlc');
