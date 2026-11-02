import { useEffect, useRef, useState } from 'react';
import { Directory, File, Paths } from 'expo-file-system';
import { AppState, Button, Image, Platform, Pressable, SafeAreaView, ScrollView, StyleSheet, Text, TextInput, View } from 'react-native';
import Player, { PlayerView, type MediaInspection, type MediaThumbnail, type PlaybackStatus, type PlaybackTracks, type PlaybackTrackType, type PlaylistItem, type RepeatMode, type SubtitleStyle, type VideoResizeMode } from '../src';
import FrameProbePreview from './FrameProbePreview';

function formatTime(millis: number): string {
  const seconds = Math.floor(Math.max(0, millis) / 1000);
  return `${Math.floor(seconds / 60)}:${String(seconds % 60).padStart(2, '0')}`;
}

function deleteThumbnail(uri: string | null) {
  if (!uri) return;
  try {
    const file = new File(uri);
    if (file.exists) file.delete();
  } catch {
    // Temporary files may already have been removed by the system.
  }
}

function TrackOption({ label, selected, disabled, onPress }: { label: string; selected: boolean; disabled: boolean; onPress: () => void }) {
  return (
    <Pressable accessibilityRole="radio" accessibilityState={{ selected, disabled }} disabled={disabled} onPress={onPress} style={styles.trackOption}>
      <View style={[styles.trackBox, selected && styles.trackBoxSelected]}>
        {selected && <Text style={styles.trackCheck}>✓</Text>}
      </View>
      <Text style={styles.trackLabel}>{label}</Text>
    </Pressable>
  );
}

async function prepareFiles(urls: string[], progress: (message: string) => void): Promise<string[]> {
  const key = urls.join('\n');
  let hash = 2166136261;
  for (let i = 0; i < key.length; i++) hash = Math.imul(hash ^ key.charCodeAt(i), 16777619);
  const directory = new Directory(Paths.document, 'playlist-preview', (hash >>> 0).toString(16));
  const manifest = new File(directory, 'sources.json');
  const files = Array.from({ length: 5 }, (_, index) => new File(directory, `item-${index + 1}.mp4`));
  if (manifest.exists && await manifest.text() === key && files.every((file) => file.exists && file.size > 0)) {
    progress('Using the saved local files.');
    return files.map((file) => file.uri);
  }

  if (directory.exists) directory.delete();
  directory.create({ intermediates: true, idempotent: true });
  try {
    for (let index = 0; index < 2; index++) {
      progress(`Downloading video ${index + 1} of 2…`);
      await File.downloadFileAsync(urls[index], files[index]);
      if (!files[index].exists || files[index].size === 0) throw new Error('Downloaded file is empty');
    }
    for (let index = 2; index < files.length; index++) {
      progress(`Creating local copy ${index + 1} of 5…`);
      await files[index % 2].copy(files[index]);
    }
    manifest.create();
    manifest.write(key);
    return files.map((file) => file.uri);
  } catch (error) {
    if (directory.exists) directory.delete();
    throw error;
  }
}

export default function App() {
  const [sessionId, setSessionId] = useState<string | null>(null);
  const [sessionBusy, setSessionBusy] = useState(true);
  const [sessionCounts, setSessionCounts] = useState({ created: 0, released: 0 });
  const [firstUri, setFirstUri] = useState('https://download.samplelib.com/mp4/sample-5s.mp4');
  const [secondUri, setSecondUri] = useState('https://cdn.truefilesize.com/mp4/sample-portrait.mp4');
  const [message, setMessage] = useState('Creating session…');
  const [busy, setBusy] = useState(false);
  const [ready, setReady] = useState(false);
  const [resizeMode, setResizeMode] = useState<VideoResizeMode>('contain');
  const [playlistSize, setPlaylistSize] = useState(0);
  const [playlistItems, setPlaylistItems] = useState<PlaylistItem[]>([]);
  const [playlistEditing, setPlaylistEditing] = useState(false);
  const [errorTestResult, setErrorTestResult] = useState<string | null>(null);
  const [subtitleStyle, setSubtitleStyle] = useState<SubtitleStyle>({ fontScale: 1.5, textColor: 0xffffff, backgroundColor: 0, backgroundOpacity: 0, outlineColor: 0, outlineWidth: 4, bottomMargin: 30, alignment: -1 });
  const [appliedSubtitleStyle, setAppliedSubtitleStyle] = useState<SubtitleStyle | null>(null);
  const [playback, setPlayback] = useState<PlaybackStatus | null>(null);
  const [trackState, setTrackState] = useState<{ sessionId: string; snapshot: PlaybackTracks } | null>(null);
  const [trackBusy, setTrackBusy] = useState(false);
  const [history, setHistory] = useState<string[]>([]);
  const [barWidth, setBarWidth] = useState(0);
  const [preview, setPreview] = useState<number | null>(null);
  const [seekPrecision, setSeekPrecision] = useState<'fast' | 'precise'>('fast');
  const [pipSupported, setPipSupported] = useState(false);
  const [pipReason, setPipReason] = useState<string | null>(null);
  const [pipEvent, setPipEvent] = useState('No PiP event yet');
  const [pipMode, setPipMode] = useState(false);
  const [controlCenterEnabled, setControlCenterEnabled] = useState(false);
  const [controlCenterBusy, setControlCenterBusy] = useState(false);
  const [probeUri, setProbeUri] = useState<string | null>(null);
  const [probeActive, setProbeActive] = useState(false);
  const [probeFrames, setProbeFrames] = useState(0);
  const [probePip, setProbePip] = useState<{ supported: boolean; possible: boolean; active: boolean; starting: boolean; error: string | null } | null>(null);
  const [analysisUri, setAnalysisUri] = useState<string | null>(null);
  const [analysisBusy, setAnalysisBusy] = useState(false);
  const [analysisMessage, setAnalysisMessage] = useState('Inspect the URL, or save the files before generating a thumbnail.');
  const [inspection, setInspection] = useState<MediaInspection | null>(null);
  const [thumbnail, setThumbnail] = useState<MediaThumbnail | null>(null);
  const [thumbnailPosition, setThumbnailPosition] = useState('1000');
  const analysisRequest = useRef<string | null>(null);
  const thumbnailFile = useRef<string | null>(null);
  const requestSequence = useRef(0);
  const dragItem = useRef<number | null>(null);
  const pendingSeek = useRef<{ index: number; target: number; deadline: number; sent: boolean } | null>(null);
  const sessionRef = useRef<string | null>(null);
  const tracksRequest = useRef(0);
  const trackSnapshot = useRef<PlaybackTracks | null>(null);
  const sessionOperation = useRef(false);
  const mounted = useRef(false);
  const tracks = trackState?.sessionId === sessionId && trackState.snapshot.currentIndex === playback?.currentIndex
    ? trackState.snapshot : null;

  function setTracks(snapshot: PlaybackTracks | null) {
    const id = sessionRef.current;
    setTrackState(snapshot && id ? { sessionId: id, snapshot } : null);
  }

  useEffect(() => { trackSnapshot.current = tracks; }, [tracks]);

  function record(text: string) {
    const entry = `${new Date().toLocaleTimeString()} ${text}`;
    setHistory((previous) => [entry, ...previous].slice(0, 30));
  }

  useEffect(() => { tracksRequest.current += 1; }, [sessionId, playback?.currentIndex]);

  async function refreshTracks() {
    const id = sessionRef.current;
    if (!id) return;
    const request = ++tracksRequest.current;
    setTrackBusy(true);
    try {
      const result = await Player.getTracks(id);
      if (sessionRef.current === id && tracksRequest.current === request) setTracks(result);
    } catch (error) {
      if (sessionRef.current === id && tracksRequest.current === request) { setTracks(null); setMessage(`Tracks: ${String(error)}`); }
    } finally { setTrackBusy(false); }
  }

  async function selectTrack(type: PlaybackTrackType, id: string | null) {
    const session = sessionRef.current;
    if (!session || !tracks) return;
    setTrackBusy(true);
    try {
      await Player.selectTrack(session, type, id, tracks.revision);
      if (sessionRef.current === session) setMessage('Track selection requested.');
    } catch (error) {
      if (sessionRef.current === session) { setTracks(null); setMessage(`Track selection: ${String(error)}`); }
    } finally { setTrackBusy(false); }
  }

  useEffect(() => {
    if (!sessionId) return;
    const subscription = Player.addListener('onTracksChanged', (event) => {
      const snapshot = trackSnapshot.current;
      if (event.sessionId !== sessionId || sessionRef.current !== sessionId || !snapshot || snapshot.revision !== event.revision) return;
      const request = ++tracksRequest.current;
      void Player.getTracks(sessionId).then((result) => {
        if (sessionRef.current === sessionId && tracksRequest.current === request && trackSnapshot.current?.revision === result.revision) setTracks(result);
      }).catch(() => {});
    });
    return () => subscription.remove();
  }, [sessionId]);

  useEffect(() => {
    let disposed = false;
    mounted.current = true;
    sessionOperation.current = true;
    setSessionBusy(true);
    Player.createSession().then((created) => {
      if (disposed) void Player.release(created).catch(() => {});
      else {
        sessionRef.current = created;
        setSessionId(created);
        setSessionCounts((counts) => ({ ...counts, created: counts.created + 1 }));
        setMessage('Load the local playlist before switching.');
      }
    }).catch((error: unknown) => { if (!disposed) setMessage(`Create session: ${String(error)}`); })
      .finally(() => { if (!disposed) { sessionOperation.current = false; setSessionBusy(false); } });
    return () => {
      disposed = true;
      mounted.current = false;
      const id = sessionRef.current;
      sessionRef.current = null;
      if (id && !sessionOperation.current) void Player.release(id).catch(() => {});
    };
  }, []);

  async function createSession() {
    if (sessionOperation.current || sessionRef.current) return;
    sessionOperation.current = true;
    setSessionBusy(true);
    try {
      const id = await Player.createSession();
      if (!mounted.current) { await Player.release(id); return; }
      sessionRef.current = id;
      setSessionId(id);
      setAppliedSubtitleStyle(null);
      setSessionCounts((counts) => ({ ...counts, created: counts.created + 1 }));
      setMessage('Session created. Load the local playlist.');
      record('Session created');
    } catch (error) {
      if (mounted.current) setMessage(`Create session: ${String(error)}`);
    } finally {
      sessionOperation.current = false;
      if (mounted.current) setSessionBusy(false);
    }
  }

  function clearSessionDisplay() {
    setSessionId(null);
    setControlCenterEnabled(false);
    setReady(false);
    setPlayback(null);
    setPlaylistItems([]);
    setPlaylistSize(0);
    setPipSupported(false);
    setPipMode(false);
    setPipReason(null);
    pendingSeek.current = null;
    dragItem.current = null;
    setPreview(null);
  }

  async function releaseSession() {
    const id = sessionRef.current;
    if (!id || sessionOperation.current || busy || probeActive) return;
    sessionOperation.current = true;
    setSessionBusy(true);
    try {
      await Player.release(id);
      if (sessionRef.current === id) sessionRef.current = null;
      if (!mounted.current) return;
      clearSessionDisplay();
      setSessionCounts((counts) => ({ ...counts, released: counts.released + 1 }));
      setMessage('Session released. Create a session to continue.');
      record('Session released');
    } catch (error) {
      if (mounted.current) {
        const code = typeof error === 'object' && error !== null && 'code' in error ? error.code : null;
        const text = String(error);
        if (code === 'ERR_PLAYER_RELEASE_TIMEOUT' || text.includes('Native player cleanup is still running')) {
          if (sessionRef.current === id) sessionRef.current = null;
          clearSessionDisplay();
          setMessage('The session is closed, but native cleanup is still running. Try Create session again after cleanup finishes.');
        } else setMessage(`Release session: ${text}`);
      }
    } finally {
      sessionOperation.current = false;
      if (mounted.current) setSessionBusy(false);
    }
  }

  useEffect(() => {
    if (!sessionId) return;
    let active = true;
    let pending = false;
    let queued = false;
    let observedStateSequence = 0;
    let progressIdentity: { revision: string; index: number; itemId: string | null; sequence: number } | null = null;
    const confirmSeek = (index: number, position: number) => {
      const seek = pendingSeek.current;
      if (seek && dragItem.current === null && (index !== seek.index ||
        (seek.sent && Math.abs(position - seek.target) < 750) || Date.now() > seek.deadline)) {
        if (index === seek.index && Date.now() > seek.deadline) setMessage('Seek was not confirmed by the player.');
        pendingSeek.current = null;
        setPreview(null);
      }
    };
    const poll = async () => {
      if (pending) { queued = true; return; }
      pending = true;
      try {
        const next = await Player.getPlaybackStatus(sessionId);
        if (!active || sessionOperation.current || sessionRef.current !== sessionId) return;
        if (next.eventSequence < observedStateSequence) { queued = true; return; }
        const newerProgress = progressIdentity?.revision === next.mediaRevision && progressIdentity.index === next.currentIndex &&
          progressIdentity.itemId === next.currentItemId && progressIdentity.sequence > next.progressSequence;
        if (!newerProgress) progressIdentity = { revision: next.mediaRevision, index: next.currentIndex, itemId: next.currentItemId, sequence: next.progressSequence };
        setPlayback((previous) => previous && previous.mediaRevision === next.mediaRevision && previous.progressSequence > next.progressSequence
          ? { ...next, positionMillis: previous.positionMillis, durationMillis: previous.durationMillis, progressSequence: previous.progressSequence }
          : next);
        if (!newerProgress) confirmSeek(next.currentIndex, next.positionMillis);
      } catch (error) {
        if (active && !sessionOperation.current && sessionRef.current === sessionId) setMessage(String(error));
      } finally {
        pending = false;
        if (active && queued) { queued = false; void poll(); }
      }
    };
    const progress = Player.addListener('onPlaybackProgress', (event) => {
      if (!active || sessionOperation.current || event.sessionId !== sessionId || sessionRef.current !== sessionId) return;
      if (!progressIdentity || progressIdentity.revision !== event.mediaRevision || progressIdentity.index !== event.currentIndex ||
          progressIdentity.itemId !== event.currentItemId || progressIdentity.sequence >= event.sequence) return;
      progressIdentity.sequence = event.sequence;
      setPlayback((previous) => {
        if (!previous || previous.mediaRevision !== event.mediaRevision || previous.currentIndex !== event.currentIndex ||
            previous.currentItemId !== event.currentItemId || previous.progressSequence >= event.sequence) return previous;
        return { ...previous, positionMillis: event.positionMillis, durationMillis: event.durationMillis, progressSequence: event.sequence };
      });
      confirmSeek(event.currentIndex, event.positionMillis);
    });
    const states = Player.addListener('onPlaybackStateChange', (event) => {
      if (event.sessionId !== sessionId) return;
      observedStateSequence = Math.max(observedStateSequence, event.sequence);
      void poll();
    });
    void poll();
    const timer = setInterval(() => void poll(), 1000);
    return () => { active = false; clearInterval(timer); progress.remove(); states.remove(); };
  }, [sessionId]);

  useEffect(() => {
    if (!probeActive) return;
    let active = true;
    const poll = () => {
      void Player.getFrameProbeStatus().then((status) => {
        if (active) setProbeFrames(status.frames);
      }).catch((error: unknown) => { if (active) setMessage(`Frame probe: ${String(error)}`); });
      void Player.getFrameProbePictureInPictureState().then((status) => {
        if (active) setProbePip(status);
      }).catch((error: unknown) => { if (active) setMessage(`Probe PiP: ${String(error)}`); });
    };
    poll();
    const timer = setInterval(poll, 500);
    return () => { active = false; clearInterval(timer); };
  }, [probeActive]);

  useEffect(() => () => {
    if (Platform.OS === 'ios') void Player.stopFrameProbe().catch(() => {});
  }, []);

  useEffect(() => () => {
    if (analysisRequest.current) void Player.cancelMediaJob(analysisRequest.current).catch(() => {});
    deleteThumbnail(thumbnailFile.current);
    thumbnailFile.current = null;
  }, []);

  useEffect(() => {
    if (!sessionId) return;
    let active = true;
    const update = async () => {
      try {
        const state = await Player.getPictureInPictureState(sessionId);
        if (active && !sessionOperation.current && sessionRef.current === sessionId) { setPipSupported(state.supported); setPipMode(state.active); setPipReason(state.reason); }
      } catch (error) {
        if (active && !sessionOperation.current && sessionRef.current === sessionId) setMessage(`PiP status: ${String(error)}`);
      }
    };
    void update();
    const timer = Platform.OS === 'ios' ? setInterval(() => void update(), 1000) : null;
    const subscription = AppState.addEventListener('change', (state) => {
      if (state === 'active') void update();
    });
    const pipSubscription = Player.addListener('onPictureInPictureStateChange', (event) => {
      if (event.sessionId !== sessionId || sessionRef.current !== sessionId) return;
      setPipSupported(event.supported);
      setPipMode(event.active);
      setPipReason(event.reason);
      setPipEvent(event.reason ? `PiP error: ${event.reason}` : `PiP ${event.active ? 'started' : 'stopped'}`);
      console.log('PiP state:', event);
    });
    const testSubscription = Player.addListener('onPictureInPictureExitTest', (event) => {
      if (event.sessionId !== sessionId || sessionRef.current !== sessionId) return;
      const result = `PiP exit test: ${event.stage}${event.message ? ` — ${event.message}` : ''}`;
      setPipEvent(result);
      console.log('PiP exit test:', event);
    });
    return () => { active = false; if (timer) clearInterval(timer); subscription.remove(); pipSubscription.remove(); testSubscription.remove(); };
  }, [sessionId]);

  useEffect(() => {
    if (!sessionId) return;
    const subscription = Player.addListener('onPlaybackStateChange', (event) => {
      if (event.sessionId === sessionId) record(`#${event.sequence} ${event.currentItemId ?? 'no item'}: ${event.state}`);
    });
    const errors = Player.addListener('onPlaybackError', (event) => {
      if (event.sessionId === sessionId) {
        setMessage(`Playback: ${event.code} — ${event.message}`);
        if (event.currentItemId?.startsWith('error-test-')) {
          setErrorTestResult(`#${event.sequence} · ${event.currentItemId} · ${event.code}: ${event.message}`);
          console.log('Playback error test:', event);
        }
      }
    });
    return () => { subscription.remove(); errors.remove(); };
  }, [sessionId]);

  async function prepare() {
    if (!sessionId || busy || sessionBusy || analysisBusy) return;
    pendingSeek.current = null;
    setPreview(null);
    setBusy(true);
    setReady(false);
    let stage = 'Checking native module';
    try {
      if (typeof Player.next !== 'function' || typeof Player.previous !== 'function' || typeof Player.seekTo !== 'function') {
        throw new Error('Native player is out of date. Rebuild and reinstall the development app.');
      }
      stage = 'Stopping playback';
      await Player.stop(sessionId);
      stage = 'Preparing files';
      const files = await prepareFiles([firstUri.trim(), secondUri.trim()], (progress) => {
        stage = progress;
        setMessage(progress);
      });
      setProbeUri(files[0]);
      setAnalysisUri(files[0]);
      stage = 'Registering playlist';
      await Player.setPlaylistItems(sessionId, files.map((uri, index) => ({ id: `item-${index + 1}`, uri, title: `Video ${index + 1}` })));
      setPlaylistItems(await Player.getPlaylist(sessionId));
      setPlaylistSize(files.length);
      stage = 'Starting the first item';
      await Player.selectPlaylistItem(sessionId, 0);
      setReady(true);
      setMessage('Five local files ready. Use Previous and Next to switch.');
      record('Local playlist ready; requested item 1');
    } catch (error) { setMessage(`${stage}: ${String(error)}`); }
    finally { setBusy(false); }
  }

  async function testPlaybackError() {
    if (!sessionId || busy || sessionBusy || playlistEditing || probeActive || analysisBusy || (Platform.OS === 'android' && pipMode)) return;
    setBusy(true);
    setReady(false);
    setErrorTestResult(null);
    pendingSeek.current = null;
    setPreview(null);
    try {
      const missing = new File(Paths.cache, `missing-video-${Date.now()}-${Math.random().toString(36).slice(2)}.mp4`);
      setMessage('Error test: stopping playback…');
      await Player.stop(sessionId);
      setMessage('Error test: preparing the missing file…');
      await Player.setFailurePolicy(sessionId, 'stop');
      await Player.setRepeatMode(sessionId, 'off');
      await Player.setShuffleEnabled(sessionId, false);
      await Player.setPlaylistItems(sessionId, [{ id: 'error-test-missing-file', uri: missing.uri, title: 'Missing file' }]);
      setPlaylistItems(await Player.getPlaylist(sessionId));
      setPlaylistSize(1);
      setMessage('Error test: waiting for a playback error event…');
      await Player.selectItem(sessionId, 'error-test-missing-file');
      setReady(true);
    } catch (error) {
      const result = `Error test command failed: ${String(error)}`;
      setErrorTestResult(result);
      setMessage(result);
    } finally { setBusy(false); }
  }

  async function testFailureSkip(allFail: boolean) {
    if (!sessionId || busy || sessionBusy || playlistEditing || probeActive || analysisBusy || (!allFail && !probeUri) || (Platform.OS === 'android' && pipMode)) return;
    setBusy(true);
    setReady(false);
    setErrorTestResult(null);
    pendingSeek.current = null;
    setPreview(null);
    try {
      const token = `${Date.now()}-${Math.random().toString(36).slice(2)}`;
      const missing = (suffix: string) => new File(Paths.cache, `missing-${token}-${suffix}.mp4`).uri;
      const items: PlaylistItem[] = [
        { id: 'error-test-first', uri: missing('first'), title: 'Missing file 1' },
        allFail
          ? { id: 'error-test-second', uri: missing('second'), title: 'Missing file 2' }
          : { id: 'error-test-valid', uri: probeUri!, title: 'Playable file' },
      ];
      setMessage(allFail ? 'Testing all-failure limit…' : 'Testing skip to the playable file…');
      await Player.stop(sessionId);
      await Player.setFailurePolicy(sessionId, 'skip');
      await Player.setRepeatMode(sessionId, allFail ? 'all' : 'off');
      await Player.setShuffleEnabled(sessionId, false);
      await Player.setPlaylistItems(sessionId, items);
      setPlaylistItems(await Player.getPlaylist(sessionId));
      setPlaylistSize(items.length);
      await Player.selectItem(sessionId, items[0].id);
      setReady(true);
    } catch (error) {
      const result = `Failure skip test: ${String(error)}`;
      setErrorTestResult(result);
      setMessage(result);
    } finally { setBusy(false); }
  }

  async function editPlaylist(action: (id: string) => Promise<void>) {
    if (!sessionId || playlistEditing || sessionBusy || busy) return;
    setPlaylistEditing(true);
    try {
      await action(sessionId);
      const items = await Player.getPlaylist(sessionId);
      const current = await Player.getCurrentItem(sessionId);
      setPlaylistItems(items);
      setPlaylistSize(items.length);
      setReady(current !== null);
      setPlayback(await Player.getPlaybackStatus(sessionId));
      setMessage('Playlist updated.');
    } catch (error) { setMessage(`Playlist: ${String(error)}`); }
    finally { setPlaylistEditing(false); }
  }

  async function subtitleFixtureUri(): Promise<string> {
    const source = Image.resolveAssetSource(require('./assets/subtitle-fixture/subtitles-text.mkv'));
    if (!source?.uri) throw new Error('Subtitle test video is unavailable');
    if (source.uri.startsWith('file://')) return source.uri;
    if (!/^https?:\/\//i.test(source.uri)) throw new Error(`Unsupported asset URI: ${source.uri}`);
    const directory = new Directory(Paths.document, 'subtitle-fixture');
    directory.create({ intermediates: true, idempotent: true });
    const file = new File(directory, 'subtitles-text-v1.mkv');
    if (!file.exists || file.size === 0) {
      if (file.exists) file.delete();
      await File.downloadFileAsync(source.uri, file);
    }
    return file.uri;
  }

  function selectTestSubtitle(id: string): Promise<PlaybackTracks> {
    return new Promise((resolve, reject) => {
      let settled = false;
      let checking = false;
      let lastError: unknown;
      let requestedTrack: string | null = null;
      const cleanup = () => {
        clearInterval(timer);
        clearTimeout(deadline);
        trackSubscription.remove();
        stateSubscription.remove();
      };
      const check = async () => {
        if (settled || checking) return;
        if (!mounted.current || sessionRef.current !== id) {
          settled = true;
          cleanup();
          reject(new Error('Subtitle test session ended'));
          return;
        }
        checking = true;
        try {
          const snapshot = await Player.getTracks(id);
          const track = snapshot.subtitles.find((item) => item.language?.toLowerCase().startsWith('en')) ?? snapshot.subtitles[0];
          if (!track || settled) return;
          const key = `${snapshot.revision}:${track.id}`;
          if (!track.selected) {
            if (requestedTrack !== key) {
              await Player.selectTrack(id, 'subtitle', track.id, snapshot.revision);
              requestedTrack = key;
            }
            return;
          }
          if (settled) return;
          settled = true;
          cleanup();
          resolve(snapshot);
        } catch (error) { lastError = error; }
        finally { checking = false; }
      };
      const trackSubscription = Player.addListener('onTracksChanged', (event) => { if (event.sessionId === id) void check(); });
      const stateSubscription = Player.addListener('onPlaybackStateChange', (event) => { if (event.sessionId === id) void check(); });
      const timer = setInterval(() => void check(), 300);
      const deadline = setTimeout(() => {
        if (settled) return;
        settled = true;
        cleanup();
        reject(new Error(`Subtitle track was not ready${lastError ? `: ${String(lastError)}` : ''}`));
      }, 15000);
      void check();
    });
  }

  async function startSubtitleTest() {
    if (sessionOperation.current || busy || probeActive || analysisBusy || (Platform.OS === 'android' && pipMode)) return;
    sessionOperation.current = true;
    setSessionBusy(true);
    setBusy(true);
    let newSession: string | null = null;
    try {
      setMessage('Preparing subtitle test…');
      const uri = await subtitleFixtureUri();
      const oldSession = sessionRef.current;
      if (oldSession) {
        await Player.release(oldSession);
        if (sessionRef.current === oldSession) sessionRef.current = null;
        setSessionId(null);
        setSessionCounts((counts) => ({ ...counts, released: counts.released + 1 }));
      }
      setReady(false);
      setPlayback(null);
      setTracks(null);
      setControlCenterEnabled(false);
      setPipSupported(false);
      setPipMode(false);
      setPipReason(null);
      pendingSeek.current = null;
      dragItem.current = null;
      setPreview(null);
      const style: SubtitleStyle = { ...subtitleStyle };
      newSession = await Player.createSessionWithSubtitleStyle(style);
      if (!mounted.current) { await Player.release(newSession); return; }
      sessionRef.current = newSession;
      setSessionId(newSession);
      setAppliedSubtitleStyle(style);
      setSessionCounts((counts) => ({ ...counts, created: counts.created + 1 }));
      setPlaylistSize(1);
      setProbeUri(uri);
      setAnalysisUri(uri);
      await Player.setRepeatMode(newSession, 'one');
      await Player.setPlaylist(newSession, [uri]);
      setPlaylistItems(await Player.getPlaylist(newSession));
      await Player.selectPlaylistItem(newSession, 0);
      setReady(true);
      setMessage('Video playing; selecting the subtitle track…');
      const snapshot = await selectTestSubtitle(newSession);
      if (mounted.current && sessionRef.current === newSession) {
        setTracks(snapshot);
        const pip = await Player.getPictureInPictureState(newSession);
        if (!mounted.current || sessionRef.current !== newSession) return;
        setPipSupported(pip.supported);
        setPipMode(pip.active);
        setPipReason(pip.reason);
        setMessage('Subtitle test started. Video repeats automatically.');
        record('Subtitle test started');
      }
    } catch (error) {
      if (!mounted.current && newSession && sessionRef.current === newSession) {
        sessionRef.current = null;
        void Player.release(newSession).catch(() => {});
      } else if (mounted.current) {
        const text = String(error);
        if (text.includes('Native player cleanup is still running')) { sessionRef.current = null; setSessionId(null); }
        setMessage(`Subtitle test: ${text}`);
      }
    } finally {
      sessionOperation.current = false;
      if (mounted.current) { setSessionBusy(false); setBusy(false); }
    }
  }

  async function saveAnalysisFiles() {
    if (analysisBusy || busy) return;
    setAnalysisBusy(true);
    try {
      const files = await prepareFiles([firstUri.trim(), secondUri.trim()], setAnalysisMessage);
      setAnalysisUri(files[0]);
      setAnalysisMessage('Saved the first file for inspection and thumbnails.');
    } catch (error) { setAnalysisMessage(`Save files: ${String(error)}`); }
    finally { setAnalysisBusy(false); }
  }

  async function analyze(kind: 'metadata' | 'thumbnail') {
    if (analysisRequest.current || analysisBusy) return;
    const position = Number(thumbnailPosition);
    if (kind === 'thumbnail' && (!analysisUri || !thumbnailPosition.trim() || !Number.isFinite(position) || position < 0)) {
      setAnalysisMessage('Save the files and enter a non-negative position in milliseconds.');
      return;
    }
    const id = `example-${Date.now()}-${++requestSequence.current}`;
    analysisRequest.current = id;
    setAnalysisBusy(true);
    setAnalysisMessage(kind === 'metadata' ? 'Inspecting media…' : 'Generating thumbnail…');
    try {
      if (kind === 'metadata') {
        const result = await Player.inspectMedia(id, analysisUri ?? firstUri.trim(), 15000);
        if (!mounted.current) return;
        setInspection(result);
        setAnalysisMessage('Metadata ready.');
      } else if (analysisUri) {
        const result = await Player.generateThumbnail(id, analysisUri, position, 15000);
        if (!mounted.current) { const file = new File(result.uri); if (file.exists) file.delete(); return; }
        deleteThumbnail(thumbnailFile.current);
        thumbnailFile.current = result.uri;
        setThumbnail(result);
        setAnalysisMessage('Thumbnail ready.');
      }
    } catch (error) {
      if (mounted.current) {
        const code = typeof error === 'object' && error !== null && 'code' in error ? error.code : null;
        const text = String(error);
        setAnalysisMessage(code === 'ERR_MEDIA_CANCELLED' || text.includes('ERR_MEDIA_CANCELLED') || text.includes('Media analysis was cancelled') ? 'Analysis cancelled.' : `Analysis: ${text}`);
      }
    }
    finally {
      if (analysisRequest.current === id) analysisRequest.current = null;
      if (mounted.current) setAnalysisBusy(false);
    }
  }

  async function move(direction: 'previous' | 'next') {
    if (!sessionId || !ready) return;
    pendingSeek.current = null;
    setPreview(null);
    record(`Requested ${direction}`);
    try {
      if (direction === 'next') await Player.next(sessionId);
      else await Player.previous(sessionId);
    } catch (error) { setMessage(`${direction}: ${String(error)}`); }
  }

  async function toggleControlCenter() {
    if (!sessionId || controlCenterBusy) return;
    setControlCenterBusy(true);
    try {
      const enabled = !controlCenterEnabled;
      await Player.setControlCenterEnabled(sessionId, enabled);
      setControlCenterEnabled(enabled);
      setMessage(`Control Center ${enabled ? 'enabled' : 'disabled'}.`);
    } catch (error) {
      setMessage(`Control Center: ${String(error)}`);
    } finally {
      setControlCenterBusy(false);
    }
  }

  async function changeRepeat() {
    if (!sessionId || !playback) return;
    const modes: RepeatMode[] = ['off', 'one', 'all'];
    const mode = modes[(modes.indexOf(playback.repeatMode) + 1) % modes.length];
    try {
      await Player.setRepeatMode(sessionId, mode);
      setPlayback(await Player.getPlaybackStatus(sessionId));
      record(`Repeat: ${mode}`);
    } catch (error) { setMessage(`Repeat: ${String(error)}`); }
  }

  async function changeShuffle() {
    if (!sessionId || !playback) return;
    try {
      await Player.setShuffleEnabled(sessionId, !playback.shuffleEnabled);
      setPlayback(await Player.getPlaybackStatus(sessionId));
      record(`Shuffle: ${!playback.shuffleEnabled ? 'on' : 'off'}`);
    } catch (error) { setMessage(`Shuffle: ${String(error)}`); }
  }

  async function startPip() {
    if (!sessionId || !pipSupported) return;
    try {
      await Player.startPictureInPicture(sessionId);
      if (Platform.OS === 'android') setPipMode(true);
    } catch (error) {
      setPipMode(false);
      setMessage(`PiP: ${String(error)}`);
    }
  }

  async function stopPip() {
    if (!sessionId) return;
    try { await Player.stopPictureInPicture(sessionId); }
    catch (error) { setMessage(`Stop PiP: ${String(error)}`); }
  }

  async function testPipExit(delayMillis = 5000) {
    if (!sessionId || !pipSupported) return;
    const id = sessionId;
    try {
      await Player.startPictureInPictureExitTest(id, delayMillis);
      if (Platform.OS === 'android') setPipMode(true);
      setMessage(`Native PiP exit request scheduled in ${delayMillis / 1000} seconds.`);
    } catch (error) { setMessage(`PiP test: ${String(error)}`); }
  }

  async function toggleProbe() {
    try {
      if (probeActive) {
        await Player.stopFrameProbe();
        setProbeActive(false);
      } else if (probeUri && sessionId) {
        await Player.pause(sessionId);
        setProbeFrames(0);
        await Player.startFrameProbe(probeUri);
        setProbeActive(true);
      }
    } catch (error) { setMessage(`Frame probe: ${String(error)}`); }
  }

  function seekPosition(x: number): number {
    if (!playback || barWidth <= 0) return 0;
    return Math.max(0, Math.min(1, x / barWidth)) * playback.durationMillis;
  }

  async function finishSeek(x: number) {
    const target = seekPosition(x);
    if (!sessionId || !playback?.isSeekable || dragItem.current !== playback.currentIndex) {
      setPreview(null);
      return;
    }
    dragItem.current = null;
    const request = { index: playback.currentIndex, target, deadline: Date.now() + 5000, sent: false };
    pendingSeek.current = request;
    setPreview(target);
    try {
      await Player.seekTo(sessionId, target, Platform.OS === 'ios' ? { precision: seekPrecision } : undefined);
      request.sent = true;
    } catch (error) {
      if (pendingSeek.current === request) {
        pendingSeek.current = null;
        setPreview(null);
        setMessage(`Seek: ${String(error)}`);
      }
    }
  }

  const canSeek = !sessionBusy && !!playback?.isSeekable && (playback?.durationMillis ?? 0) > 0;
  const displayedPosition = preview ?? playback?.positionMillis ?? 0;
  const progress = playback?.durationMillis ? Math.max(0, Math.min(1, displayedPosition / playback.durationMillis)) : 0;

  return (
    <SafeAreaView style={[styles.root, Platform.OS === 'android' && pipMode && styles.pipRoot]}>
      <View style={Platform.OS === 'android' && pipMode ? styles.pipVideoContainer : styles.videoContainer}>
        {sessionId ? <PlayerView sessionId={sessionId} resizeMode={resizeMode} style={Platform.OS === 'android' && pipMode ? styles.pipVideo : styles.video} /> : <View style={Platform.OS === 'android' && pipMode ? styles.pipVideo : styles.video} />}
      </View>
      <ScrollView style={Platform.OS === 'android' && pipMode ? styles.hidden : undefined} contentContainerStyle={styles.content} keyboardShouldPersistTaps="handled" removeClippedSubviews={false}>
        <Text style={styles.title}>Local playlist transition</Text>
        <View style={Platform.OS === 'android' && pipMode ? styles.hidden : styles.controlGroup}>
        <Text>Video fit: {resizeMode}</Text>
        <View style={styles.controls}>
          {(['contain', 'cover', 'fill'] as const).map((mode) => <Button key={mode} title={mode} disabled={resizeMode === mode} onPress={() => setResizeMode(mode)} />)}
        </View>
        <Text>Speed: {playback?.playbackRate ?? 1}× · Volume: {Math.round((playback?.volume ?? 1) * 100)}%{playback?.muted ? ' · muted' : ''}</Text>
        <View style={styles.controls}>
          {[0.5, 1, 1.5, 2].map((rate) => <Button key={rate} title={`${rate}×`} disabled={!sessionId || sessionBusy} onPress={() => { if (sessionId) void Player.setPlaybackRate(sessionId, rate).catch((error: unknown) => setMessage(String(error))); }} />)}
        </View>
        <View style={styles.controls}>
          <Button title="Volume −" disabled={!sessionId || sessionBusy} onPress={() => { if (sessionId) void Player.setVolume(sessionId, Math.max(0, (playback?.volume ?? 1) - 0.25)).catch((error: unknown) => setMessage(String(error))); }} />
          <Button title="Volume +" disabled={!sessionId || sessionBusy} onPress={() => { if (sessionId) void Player.setVolume(sessionId, Math.min(1, (playback?.volume ?? 1) + 0.25)).catch((error: unknown) => setMessage(String(error))); }} />
          <Button title={playback?.muted ? 'Unmute' : 'Mute'} disabled={!sessionId || sessionBusy} onPress={() => { if (sessionId) void Player.setMuted(sessionId, !playback?.muted).catch((error: unknown) => setMessage(String(error))); }} />
        </View>
        <Text>Audio delay: {playback?.audioDelayMillis ?? 0} ms{playback && !playback.audioDelayApplied ? ' · not applied' : ''}</Text>
        <View style={styles.controls}>
          <Button title="−100 ms" disabled={!sessionId || !ready || sessionBusy} onPress={() => { if (sessionId) void Player.setAudioDelay(sessionId, Math.max(-10000, (playback?.audioDelayMillis ?? 0) - 100)).catch((error: unknown) => setMessage(String(error))); }} />
          <Button title="Reset delay" disabled={!sessionId || !ready || sessionBusy} onPress={() => { if (sessionId) void Player.setAudioDelay(sessionId, 0).catch((error: unknown) => setMessage(String(error))); }} />
          <Button title="+100 ms" disabled={!sessionId || !ready || sessionBusy} onPress={() => { if (sessionId) void Player.setAudioDelay(sessionId, Math.min(10000, (playback?.audioDelayMillis ?? 0) + 100)).catch((error: unknown) => setMessage(String(error))); }} />
        </View>
        {Platform.OS === 'ios' && <Button title={`Seek: ${seekPrecision}`} onPress={() => setSeekPrecision((value) => value === 'fast' ? 'precise' : 'fast')} />}
        <View style={styles.timeRow}>
          <Text>{formatTime(displayedPosition)}</Text>
          <Text>{formatTime(playback?.durationMillis ?? 0)}</Text>
        </View>
        <View
          style={styles.seekTouch}
          onLayout={(event) => setBarWidth(event.nativeEvent.layout.width)}
          onStartShouldSetResponder={() => canSeek}
          onMoveShouldSetResponder={() => canSeek}
          onResponderGrant={(event) => {
            pendingSeek.current = null;
            dragItem.current = playback?.currentIndex ?? null;
            setPreview(seekPosition(event.nativeEvent.locationX));
          }}
          onResponderMove={(event) => setPreview(seekPosition(event.nativeEvent.locationX))}
          onResponderRelease={(event) => void finishSeek(event.nativeEvent.locationX)}
          onResponderTerminationRequest={() => false}
          onResponderTerminate={() => { dragItem.current = null; setPreview(null); }}
          accessibilityRole="adjustable"
          accessibilityLabel="Playback position"
          accessibilityState={{ disabled: !canSeek }}
          accessibilityValue={{ min: 0, max: playback?.durationMillis ?? 0, now: displayedPosition }}
          accessibilityActions={[{ name: 'increment' }, { name: 'decrement' }]}
          onAccessibilityAction={(event) => {
            if (!sessionId || !canSeek) return;
            const delta = event.nativeEvent.actionName === 'increment' ? 10000 : -10000;
            void Player.seekTo(sessionId, Math.max(0, displayedPosition + delta), Platform.OS === 'ios' ? { precision: seekPrecision } : undefined).catch((error: unknown) => setMessage(`Seek: ${String(error)}`));
          }}
        >
          <View pointerEvents="none" style={styles.seekTrack}>
            <View style={[styles.seekProgress, { width: `${progress * 100}%` }]} />
          </View>
        </View>
        <Text>{message}</Text>
        <View style={styles.controls}>
          <Button title={busy ? 'Loading…' : 'Load'} disabled={!sessionId || sessionBusy || busy || probeActive || analysisBusy} onPress={() => void prepare()} />
          <Button title="Previous" disabled={!ready || sessionBusy || !playback?.canPrevious} onPress={() => void move('previous')} />
          <Button title="Play" disabled={!sessionId || !ready || sessionBusy} onPress={() => { if (sessionId) void Player.play(sessionId).catch((error: unknown) => setMessage(String(error))); }} />
          <Button title="Pause" disabled={!sessionId || !ready || sessionBusy} onPress={() => { if (sessionId) void Player.pause(sessionId).catch((error: unknown) => setMessage(String(error))); }} />
          <Button title="Next" disabled={!ready || sessionBusy || !playback?.canNext} onPress={() => void move('next')} />
          <Button title="PiP" disabled={!ready || !pipSupported || sessionBusy} onPress={() => void startPip()} />
          <Button title="Stop PiP" disabled={!pipMode || sessionBusy} onPress={() => void stopPip()} />
        </View>
        {pipReason && <Text>Picture-in-Picture: {pipReason}</Text>}
        <Text>{pipEvent}</Text>
        <Button title="Test PiP exit (5s)" disabled={!sessionId || !ready || !pipSupported || pipMode || sessionBusy} onPress={() => void testPipExit()} />
        {Platform.OS === 'ios' && <Button title="Test PiP exit (1s)" disabled={!sessionId || !ready || !pipSupported || pipMode || sessionBusy} onPress={() => void testPipExit(1000)} />}
        <Button title="Test playback error" disabled={!sessionId || sessionBusy || busy || playlistEditing || probeActive || analysisBusy || (Platform.OS === 'android' && pipMode)} onPress={() => void testPlaybackError()} />
        <View style={styles.controls}>
          <Button title="Test skip failure" disabled={!sessionId || !probeUri || sessionBusy || busy || playlistEditing || probeActive || analysisBusy || (Platform.OS === 'android' && pipMode)} onPress={() => void testFailureSkip(false)} />
          <Button title="Test all fail" disabled={!sessionId || sessionBusy || busy || playlistEditing || probeActive || analysisBusy || (Platform.OS === 'android' && pipMode)} onPress={() => void testFailureSkip(true)} />
          <Button title={`Failure: ${playback?.failurePolicy ?? 'stop'}`} disabled={!sessionId || sessionBusy} onPress={() => { if (sessionId) void Player.setFailurePolicy(sessionId, playback?.failurePolicy === 'skip' ? 'stop' : 'skip').catch((error: unknown) => setMessage(String(error))); }} />
        </View>
        <Text>Playback: {playback?.state ?? 'unknown'} · Item: {playback?.currentItemId ?? 'none'}</Text>
        {errorTestResult && <Text selectable>{errorTestResult}</Text>}
        <Text style={styles.heading}>Playlist</Text>
        <View style={styles.controls}>
          <Button title="Add copy" disabled={!sessionId || playlistEditing || playlistItems.length === 0} onPress={() => void editPlaylist((id) => Player.addItem(id, { id: `copy-${Date.now()}-${Math.random().toString(36).slice(2)}`, uri: playlistItems[0].uri, title: 'Copy' }))} />
          <Button title="Insert copy" disabled={!sessionId || playlistEditing || playlistItems.length === 0} onPress={() => void editPlaylist((id) => Player.insertItem(id, 0, { id: `copy-${Date.now()}-${Math.random().toString(36).slice(2)}`, uri: playlistItems[0].uri, title: 'Inserted copy' }))} />
          <Button title="Clear playlist" disabled={!sessionId || playlistEditing || playlistItems.length === 0} onPress={() => void editPlaylist((id) => Player.clearPlaylist(id))} />
        </View>
        {playlistItems.map((item, index) => <View key={item.id}>
          <Text>{playback?.currentIndex === index ? '▶ ' : ''}{item.title || item.id}</Text>
          <View style={styles.controls}>
            <Button title="Select" disabled={playlistEditing} onPress={() => void editPlaylist((id) => Player.selectItem(id, item.id))} />
            <Button title="↑" disabled={playlistEditing || index === 0} onPress={() => void editPlaylist((id) => Player.moveItem(id, index, index - 1))} />
            <Button title="↓" disabled={playlistEditing || index === playlistItems.length - 1} onPress={() => void editPlaylist((id) => Player.moveItem(id, index, index + 1))} />
            <Button title="Remove" disabled={playlistEditing} onPress={() => void editPlaylist((id) => Player.removeItem(id, item.id))} />
          </View>
        </View>)}
        <Text style={styles.heading}>Subtitle test</Text>
        <Text>Choose a style below, then start the video with subtitles selected and repeat enabled.</Text>
        <Text>Session: {sessionBusy ? 'working…' : sessionId ? `active (${sessionId})` : 'released'} · Created: {sessionCounts.created} · Released: {sessionCounts.released}</Text>
        <Text>Counts track successful requests in this screen, not native memory usage.</Text>
        <View style={styles.controls}>
          <Button title="Create session" disabled={!!sessionId || sessionBusy} onPress={() => void createSession()} />
          <Button title="Release session" disabled={!sessionId || sessionBusy || busy || probeActive || (Platform.OS === 'android' && pipMode)} onPress={() => void releaseSession()} />
        </View>
        <Text style={styles.heading}>Subtitle style for a new session</Text>
        <Text>Starting the test replaces the current session and applies these settings to supported text subtitles.</Text>
        <Text>Current session: {!sessionId ? 'none' : appliedSubtitleStyle ? 'styled' : 'default VLC style'}.</Text>
        <View style={styles.controls}>
          <Button title="Size −" onPress={() => setSubtitleStyle((s) => ({ ...s, fontScale: Math.max(0.5, Math.round((s.fontScale - 0.25) * 100) / 100) }))} />
          <Text>Size {subtitleStyle.fontScale}×</Text>
          <Button title="Size +" onPress={() => setSubtitleStyle((s) => ({ ...s, fontScale: Math.min(3, Math.round((s.fontScale + 0.25) * 100) / 100) }))} />
        </View>
        <View style={styles.controls}>
          {([[0xffffff, 'White'], [0x000000, 'Black'], [0xffff00, 'Yellow']] as const).map(([color, label]) => (
            <Button key={color} title={`${subtitleStyle.textColor === color ? '✓ ' : ''}${label}`} onPress={() => setSubtitleStyle((style) => ({ ...style, textColor: color, outlineColor: color === 0 ? 0xffffff : 0x000000, outlineWidth: 4 }))} />
          ))}
        </View>
        <Button title={`Background: ${subtitleStyle.backgroundOpacity === 0 ? 'off' : 'black'}`} onPress={() => setSubtitleStyle((s) => ({ ...s, backgroundOpacity: s.backgroundOpacity === 0 ? 160 : 0 }))} />
        <Button title={`Outline: ${subtitleStyle.outlineWidth === 0 ? 'off' : 'on'}`} onPress={() => setSubtitleStyle((s) => ({ ...s, outlineWidth: s.outlineWidth === 0 ? 4 : 0 }))} />
        <View style={styles.controls}>
          {([[-1, 'Auto'], [0, 'Center'], [1, 'Left'], [2, 'Right']] as const).map(([value, label]) => (
            <Button key={value} title={`${subtitleStyle.alignment === value ? '✓ ' : ''}${label}`} onPress={() => setSubtitleStyle((style) => ({ ...style, alignment: value }))} />
          ))}
        </View>
        <Button title={`Bottom margin: ${subtitleStyle.bottomMargin}px`} onPress={() => setSubtitleStyle((s) => ({ ...s, bottomMargin: s.bottomMargin === 0 ? 30 : 0 }))} />
        <Button title="Start subtitle test" disabled={sessionBusy || busy || probeActive || analysisBusy || (Platform.OS === 'android' && pipMode)} onPress={() => void startSubtitleTest()} />
        {Platform.OS === 'ios' && <Button title="Apply size to current session" disabled={!sessionId || sessionBusy} onPress={() => { if (sessionId) void Player.setSubtitleFontScale(sessionId, subtitleStyle.fontScale).catch((error: unknown) => setMessage(`Subtitle size: ${String(error)}`)); }} />}
        <Text>Video 1 URL</Text>
        <TextInput style={styles.input} value={firstUri} onChangeText={(text) => { setFirstUri(text); setAnalysisUri(null); }} autoCapitalize="none" autoCorrect={false} />
        <Text>Video 2 URL</Text>
        <TextInput style={styles.input} value={secondUri} onChangeText={(text) => { setSecondUri(text); setAnalysisUri(null); }} autoCapitalize="none" autoCorrect={false} />
        <Text style={styles.heading}>Pre-playback media analysis</Text>
        <Text>{analysisMessage}</Text>
        <Text>Source: {analysisUri ? 'saved first file' : 'first URL (metadata only)'}</Text>
        <Button title="Save files for analysis" disabled={analysisBusy || busy} onPress={() => void saveAnalysisFiles()} />
        <Button title="Inspect metadata" disabled={analysisBusy || busy} onPress={() => void analyze('metadata')} />
        <Text>Thumbnail position (milliseconds)</Text>
        <TextInput style={styles.input} value={thumbnailPosition} onChangeText={setThumbnailPosition} keyboardType="numeric" />
        <Button title="Generate thumbnail" disabled={analysisBusy || busy || !analysisUri} onPress={() => void analyze('thumbnail')} />
        <Button title="Cancel analysis" disabled={!analysisBusy} onPress={() => { const id = analysisRequest.current; if (id) void Player.cancelMediaJob(id).catch((error: unknown) => setAnalysisMessage(String(error))); }} />
        {inspection && <Text selectable>{JSON.stringify(inspection, null, 2)}</Text>}
        {thumbnail && <View><Image source={{ uri: thumbnail.uri }} style={styles.video} resizeMode="contain" /><Text>Requested: {thumbnail.requestedPositionMillis} ms · Actual: {thumbnail.actualPositionMillis === null ? 'not reported' : `${Math.round(thumbnail.actualPositionMillis)} ms`} · {thumbnail.width} × {thumbnail.height}</Text></View>}
        <View style={styles.controls}>
          <Button title={`Repeat: ${playback?.repeatMode ?? 'off'}`} disabled={!sessionId || !playback || sessionBusy} onPress={() => void changeRepeat()} />
          <Button title={`Shuffle: ${playback?.shuffleEnabled ? 'on' : 'off'}`} disabled={!sessionId || !playback || sessionBusy} onPress={() => void changeShuffle()} />
        </View>
        {Platform.OS === 'ios' && <Button title={`Control Center: ${controlCenterEnabled ? 'On' : 'Off'}`} disabled={!sessionId || sessionBusy || controlCenterBusy} onPress={() => void toggleControlCenter()} />}
        <Text style={styles.heading}>Audio and subtitle tracks</Text>
        <Button title="Refresh tracks" disabled={!sessionId || sessionBusy || trackBusy || !ready} onPress={() => void refreshTracks()} />
        {tracks && <View>
          <Text>Audio tracks: {tracks.audio.length}</Text>
          {tracks.audio.map((track) => <TrackOption key={`audio-${track.id}`} label={track.name || track.language || track.id} selected={track.selected} disabled={trackBusy} onPress={() => void selectTrack('audio', track.id)} />)}
          <Text>Subtitle tracks: {tracks.subtitles.length}</Text>
          <TrackOption label="Subtitles off" selected={tracks.subtitles.every((track) => !track.selected)} disabled={trackBusy} onPress={() => void selectTrack('subtitle', null)} />
          {tracks.subtitles.map((track) => <TrackOption key={`subtitle-${track.id}`} label={track.name || track.language || track.id} selected={track.selected} disabled={trackBusy} onPress={() => void selectTrack('subtitle', track.id)} />)}
        </View>}
        {Platform.OS === 'ios' && (
          <View>
            <Button title={probeActive ? 'Stop iOS frame probe' : 'Start iOS frame probe'} disabled={!probeUri || !sessionId || sessionBusy || busy || !!probePip?.active || !!probePip?.starting} onPress={() => void toggleProbe()} />
            <Text>Experimental muted independent player: {probeFrames} frames received.</Text>
            {probeActive && <>
              <FrameProbePreview style={styles.video} />
              <View style={styles.controls}>
                <Button title="Probe play / replay" onPress={() => void Player.setFrameProbePlaying(true).catch((error: unknown) => setMessage(String(error)))} />
                <Button title="Probe pause" onPress={() => void Player.setFrameProbePlaying(false).catch((error: unknown) => setMessage(String(error)))} />
              </View>
              <Button title={probePip?.active ? 'Stop experimental PiP' : 'Start experimental PiP'} disabled={!!probePip?.starting || !probePip?.supported} onPress={() => void (probePip?.active ? Player.stopFrameProbePictureInPicture() : Player.startFrameProbePictureInPicture()).catch((error: unknown) => setMessage(`Probe PiP: ${String(error)}`))} />
              <Text>PiP: {probePip?.active ? 'active' : probePip?.starting ? 'starting' : probePip?.possible ? 'ready' : 'not ready'}{probePip?.error ? ` · ${probePip.error}` : ''}</Text>
            </>}
          </View>
        )}
        <Text>Current item: {playback && playback.currentIndex >= 0 ? `${playback.currentIndex + 1} / ${playlistSize}` : 'none'} · State: {playback?.state ?? 'unknown'}</Text>
        <Text>Progress uses native events; transition history uses native state events.</Text>
        <Text style={styles.heading}>Recent transitions</Text>
        {history.map((entry, index) => <Text key={`${index}-${entry}`}>{entry}</Text>)}
        </View>
      </ScrollView>
    </SafeAreaView>
  );
}

const styles = StyleSheet.create({
  root: { flex: 1, backgroundColor: 'white' },
  pipRoot: { backgroundColor: 'black' },
  content: { padding: 16, gap: 12 },
  videoContainer: { paddingHorizontal: 16, paddingTop: 16 },
  pipVideoContainer: { flex: 1 },
  title: { fontSize: 22, fontWeight: '600' },
  heading: { fontWeight: '600' },
  hidden: { display: 'none' },
  controlGroup: { gap: 12 },
  video: { width: '100%', aspectRatio: 16 / 9, backgroundColor: 'black' },
  pipVideo: { width: '100%', flex: 1, backgroundColor: 'black' },
  timeRow: { flexDirection: 'row', justifyContent: 'space-between' },
  seekTouch: { height: 32, justifyContent: 'center' },
  seekTrack: { height: 6, backgroundColor: '#ccc', borderRadius: 3, overflow: 'hidden' },
  seekProgress: { height: '100%', backgroundColor: '#276ef1' },
  input: { borderWidth: 1, borderColor: '#aaa', borderRadius: 6, padding: 8 },
  controls: { flexDirection: 'row', flexWrap: 'wrap', justifyContent: 'space-around' },
  trackOption: { flexDirection: 'row', alignItems: 'center', minHeight: 44, gap: 10 },
  trackBox: { width: 22, height: 22, borderWidth: 1, borderColor: '#555', borderRadius: 4, alignItems: 'center', justifyContent: 'center' },
  trackBoxSelected: { backgroundColor: '#276ef1', borderColor: '#276ef1' },
  trackCheck: { color: 'white', fontSize: 16, fontWeight: '700', lineHeight: 20 },
  trackLabel: { flex: 1, color: '#222' },
});
