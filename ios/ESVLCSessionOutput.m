#import "ESVLCSessionOutput.h"
#if TARGET_OS_IOS
#import <VLCKit/vlc/vlc.h>
#import <limits.h>
#import <stdatomic.h>
#import <stdint.h>

@interface ESVLCSessionOutput ()
- (void)handleMedia:(libvlc_media_t *)media;
- (void)handleState:(BOOL)failed mediaIdentity:(uintptr_t)mediaIdentity;
- (void)recordCallbackMedia:(libvlc_media_t *)media;
- (uintptr_t)callbackMediaIdentity;
- (void)handlePosition;
- (void)handleLength:(int64_t)length;
- (void)handleClockUpdate:(libvlc_media_player_time_point_t)point;
- (void)handleClockPause:(libvlc_time_t)date;
- (void)handleClockSeek:(BOOL)seeking point:(libvlc_media_player_time_point_t)point;
- (void)finishSeeks;
- (void)handleTracksChanged;
@end

static void ESMediaChanged(void *opaque, libvlc_media_t *media) {
  ESVLCSessionOutput *output = (__bridge ESVLCSessionOutput *)opaque;
  [output recordCallbackMedia:media];
  if (media) libvlc_media_retain(media);
  dispatch_async(dispatch_get_main_queue(), ^{ [output handleMedia:media]; if (media) libvlc_media_release(media); });
}
static void ESStateChanged(void *opaque, libvlc_state_t state) {
  ESVLCSessionOutput *output = (__bridge ESVLCSessionOutput *)opaque;
  uintptr_t mediaIdentity = [output callbackMediaIdentity];
  BOOL failed = state == libvlc_Error;
  dispatch_async(dispatch_get_main_queue(), ^{ [output handleState:failed mediaIdentity:mediaIdentity]; });
}
static void ESClockUpdate(void *opaque, const libvlc_media_player_time_point_t *point) {
  ESVLCSessionOutput *output = (__bridge ESVLCSessionOutput *)opaque;
  libvlc_media_player_time_point_t snapshot = *point;
  dispatch_async(dispatch_get_main_queue(), ^{ [output handleClockUpdate:snapshot]; });
}
static void ESClockPause(void *opaque, libvlc_time_t date) {
  ESVLCSessionOutput *output = (__bridge ESVLCSessionOutput *)opaque;
  dispatch_async(dispatch_get_main_queue(), ^{ [output handleClockPause:date]; });
}
static void ESClockSeek(void *opaque, const libvlc_media_player_time_point_t *point) {
  ESVLCSessionOutput *output = (__bridge ESVLCSessionOutput *)opaque;
  BOOL seeking = point != NULL;
  libvlc_media_player_time_point_t snapshot = point ? *point : (libvlc_media_player_time_point_t){0};
  dispatch_async(dispatch_get_main_queue(), ^{ [output handleClockSeek:seeking point:snapshot]; });
}
static void ESLengthChanged(void *opaque, libvlc_time_t length) {
  ESVLCSessionOutput *output = (__bridge ESVLCSessionOutput *)opaque;
  dispatch_async(dispatch_get_main_queue(), ^{ [output handleLength:length / 1000]; });
}
static void ESTrackListChanged(void *opaque, libvlc_list_action_t action, libvlc_track_type_t type, const char *identifier) {
  if (type != libvlc_track_audio && type != libvlc_track_text) return;
  ESVLCSessionOutput *output = (__bridge ESVLCSessionOutput *)opaque;
  dispatch_async(dispatch_get_main_queue(), ^{ [output handleTracksChanged]; });
}
static void ESTrackSelectionChanged(void *opaque, libvlc_track_type_t type, const char *oldID, const char *newID) {
  if (type != libvlc_track_audio && type != libvlc_track_text) return;
  ESVLCSessionOutput *output = (__bridge ESVLCSessionOutput *)opaque;
  dispatch_async(dispatch_get_main_queue(), ^{ [output handleTracksChanged]; });
}
static const struct libvlc_media_player_cbs ESPlayerCallbacks = {
  .version = 0,
  .on_media_changed = ESMediaChanged,
  .on_state_changed = ESStateChanged,
  .on_length_changed = ESLengthChanged,
  .on_track_list_changed = ESTrackListChanged,
  .on_track_selection_changed = ESTrackSelectionChanged,
};
static const struct libvlc_media_player_watch_time_cbs ESClockCallbacks = {
  .version = 0,
  .on_update = ESClockUpdate,
  .on_paused = ESClockPause,
  .on_seek = ESClockSeek,
};

@implementation ESVLCSessionOutput {
  _Atomic(uintptr_t) _callbackMedia;
  libvlc_media_list_player_t *_list;
  libvlc_media_player_t *_native;
  NSMapTable<VLCMedia *, NSValue *> *_mediaToNative;
  NSMutableDictionary<NSValue *, VLCMedia *> *_nativeToMedia;
  BOOL _closed;
  VLCLibrary *_library;
  BOOL _watchingTime;
  BOOL _hasClockPoint;
  BOOL _clockSeeking;
  libvlc_media_player_time_point_t _clockPoint;
  NSMutableArray<void (^)(void)> *_seekCompletions;
}
- (instancetype)init { return [self initWithOptions:nil]; }
- (instancetype)initWithOptions:(NSArray<NSString *> *)options {
  if (!(self = [super init])) return nil;
  atomic_init(&_callbackMedia, 0);
  _library = options ? [[VLCLibrary alloc] initWithOptions:options] : [VLCLibrary sharedLibrary];
  if (!_library || !_library.instance) return nil;
  _mediaToNative = [NSMapTable mapTableWithKeyOptions:NSPointerFunctionsStrongMemory | NSPointerFunctionsObjectPointerPersonality valueOptions:NSPointerFunctionsStrongMemory];
  _nativeToMedia = [NSMutableDictionary dictionary];
  _seekCompletions = [NSMutableArray array];
  _list = libvlc_media_list_player_new(_library.instance, &ESPlayerCallbacks, (__bridge void *)self);
  if (!_list) return nil;
  _native = libvlc_media_list_player_get_media_player(_list);
  if (!_native) { libvlc_media_list_player_release(_list); _list = NULL; return nil; }
  if (libvlc_media_player_watch_time(_native, 200000, &ESClockCallbacks, (__bridge void *)self) != 0) {
    libvlc_media_list_player_release(_list); _list = NULL;
    libvlc_media_player_release(_native); _native = NULL;
    return nil;
  }
  _watchingTime = YES;
  return self;
}
- (void *)nativePlayer { return _native; }
- (void)setSubtitleFontScale:(float)scale { if (_native) libvlc_video_set_spu_text_scale(_native, scale); }
- (BOOL)setPlaybackRate:(float)rate { return _native && libvlc_media_player_set_rate(_native, rate) == 0; }
- (BOOL)setSoftwareVolume:(int)volume { return _native && libvlc_audio_set_volume(_native, volume) == 0; }
- (BOOL)setAudioDelayMillis:(int64_t)delayMillis { return _native && libvlc_audio_set_delay(_native, delayMillis * 1000) == 0; }
- (VLCMediaPlayerState)state {
  if (!_native) return VLCMediaPlayerStateStopped;
  switch (libvlc_media_player_get_state(_native)) {
    case libvlc_NothingSpecial: return VLCMediaPlayerStateNothingSpecial;
    case libvlc_Opening: return VLCMediaPlayerStateOpening;
    case libvlc_Playing: return VLCMediaPlayerStatePlaying;
    case libvlc_Paused: return VLCMediaPlayerStatePaused;
    case libvlc_Stopping: return VLCMediaPlayerStateStopping;
    case libvlc_Stopped: return VLCMediaPlayerStateStopped;
    case libvlc_Error: return VLCMediaPlayerStateError;
    default: return VLCMediaPlayerStateOpening;
  }
}
- (BOOL)isPlaying { return _native && libvlc_media_player_is_playing(_native); }
- (BOOL)isSeekable { return _native && libvlc_media_player_is_seekable(_native); }
- (BOOL)isPlayerStopped { return !_native || libvlc_media_player_get_state(_native) == libvlc_Stopped || libvlc_media_player_get_state(_native) == libvlc_NothingSpecial; }
- (BOOL)nativeIsSeekable { return self.isSeekable; }
- (int32_t)positionMillis {
  if (!_native) return 0;
  libvlc_time_t time = -1;
  double position = 0;
  if (_hasClockPoint) libvlc_media_player_time_point_interpolate(&_clockPoint, libvlc_clock(), &time, &position);
  if (time < 0) time = libvlc_media_player_get_time(_native);
  return (int32_t)MIN(INT32_MAX, MAX(0, time / 1000));
}
- (int32_t)durationMillis { return _native ? (int32_t)MIN(INT32_MAX, MAX(0, libvlc_media_player_get_length(_native) / 1000)) : 0; }
- (void)handleMedia:(libvlc_media_t *)media {
  if (_closed) return;
  libvlc_media_t *current = _native ? libvlc_media_player_get_media(_native) : NULL;
  BOOL matches = current == media;
  if (current) libvlc_media_release(current);
  if (!matches) return;
  VLCMedia *newMedia = media ? _nativeToMedia[[NSValue valueWithPointer:media]] : nil;
  if (_media != newMedia) {
    _clockSeeking = NO;
    [self finishSeeks];
    _hasClockPoint = NO;
  }
  _media = newMedia;
  if (_media && self.mediaChanged) self.mediaChanged(_media);
}
- (void)finishSeeks {
  NSArray<void (^)(void)> *completions = [_seekCompletions copy];
  [_seekCompletions removeAllObjects];
  for (void (^completion)(void) in completions) completion();
}
- (void)recordCallbackMedia:(libvlc_media_t *)media {
  atomic_store_explicit(&_callbackMedia, (uintptr_t)media, memory_order_release);
}
- (uintptr_t)callbackMediaIdentity {
  return atomic_load_explicit(&_callbackMedia, memory_order_acquire);
}
- (void)handleState:(BOOL)failed mediaIdentity:(uintptr_t)mediaIdentity {
  if (_closed) return;
  if (self.isPlayerStopped) { _clockSeeking = NO; [self finishSeeks]; }
  VLCMedia *media = mediaIdentity ? _nativeToMedia[[NSValue valueWithPointer:(void *)mediaIdentity]] : nil;
  if (self.stateChanged) self.stateChanged(failed, media);
}
- (void)handlePosition { if (!_closed && self.timeChanged) self.timeChanged(); }
- (void)handleTracksChanged { if (!_closed && self.tracksChanged) self.tracksChanged(); }
- (void)handleClockUpdate:(libvlc_media_player_time_point_t)point {
  if (_closed) return;
  _clockPoint = point;
  _hasClockPoint = YES;
  [self handlePosition];
}
- (void)handleClockPause:(libvlc_time_t)date {
  if (_closed || !_hasClockPoint || date <= 0) return;
  libvlc_time_t time = -1;
  double position = 0;
  if (libvlc_media_player_time_point_interpolate(&_clockPoint, date, &time, &position) == 0) {
    _clockPoint.ts_us = time;
    _clockPoint.position = position;
    _clockPoint.system_date_us = INT64_MAX;
  }
  [self handlePosition];
}
- (void)handleClockSeek:(BOOL)seeking point:(libvlc_media_player_time_point_t)point {
  if (_closed) return;
  if (seeking) { _clockPoint = point; _hasClockPoint = YES; }
  BOOL finished = !seeking && _clockSeeking;
  _clockSeeking = seeking;
  [self handlePosition];
  if (finished) {
    if (self.seekFinished) self.seekFinished();
    [self finishSeeks];
  }
}
- (void)handleLength:(int64_t)length { if (!_closed && self.lengthChanged) self.lengthChanged(length); }
- (BOOL)seekToMillis:(int64_t)millis fast:(BOOL)fast {
  return _native && self.isSeekable && libvlc_media_player_set_time(_native, MAX(0, millis) * 1000, fast) == 0;
}
- (BOOL)jumpWithOffset:(int32_t)offset completion:(void (^)(void))completion {
  if (!_native || !self.isSeekable) return NO;
  int64_t current = self.positionMillis;
  int64_t target = MAX(0, current + offset);
  if (target == current) { completion(); return YES; }
  [_seekCompletions addObject:[completion copy]];
  if (libvlc_media_player_set_time(_native, target * 1000, false) != 0) {
    [_seekCompletions removeLastObject];
    return NO;
  }
  return YES;
}
- (void)play { if (_native) libvlc_media_player_play(_native); }
- (void)pause { if (_native) libvlc_media_player_set_pause(_native, 1); }
- (void)stop { if (_native) libvlc_media_player_stop_async(_native); }
- (void)stopList { if (_list) libvlc_media_list_player_stop_async(_list); }
- (void)setMediaItems:(NSArray<VLCMedia *> *)items {
  if (!_list) return;
  libvlc_media_list_t *list = libvlc_media_list_new();
  if (!list) return;
  libvlc_media_list_lock(list);
  for (VLCMedia *media in items) {
    NSValue *value = [_mediaToNative objectForKey:media];
    libvlc_media_t *nativeMedia = value.pointerValue;
    if (!nativeMedia && media.url) {
      nativeMedia = libvlc_media_new_location(media.url.absoluteString.UTF8String);
      if (nativeMedia) {
        value = [NSValue valueWithPointer:nativeMedia];
        [_mediaToNative setObject:value forKey:media];
        _nativeToMedia[value] = media;
      }
    }
    if (nativeMedia) libvlc_media_list_add_media(list, nativeMedia);
  }
  libvlc_media_list_unlock(list);
  libvlc_media_list_player_set_media_list(_list, list);
  libvlc_media_list_release(list);
  for (VLCMedia *old in _mediaToNative.keyEnumerator.allObjects) {
    BOOL keep = old == _media;
    for (VLCMedia *item in items) if (old == item) { keep = YES; break; }
    if (!keep) {
      NSValue *value = [_mediaToNative objectForKey:old];
      [_mediaToNative removeObjectForKey:old];
      [_nativeToMedia removeObjectForKey:value];
      libvlc_media_release(value.pointerValue);
    }
  }
}
- (void)loadMedia:(VLCMedia *)media {
  libvlc_media_t *nativeMedia = [_mediaToNative objectForKey:media].pointerValue;
  if (_native && nativeMedia) libvlc_media_player_set_media(_native, nativeMedia);
}
static libvlc_track_type_t ESTrackType(NSString *type) {
  return [type isEqualToString:@"audio"] ? libvlc_track_audio : libvlc_track_text;
}
- (NSArray<NSDictionary<NSString *, id> *> *)tracksForType:(NSString *)type {
  if (!_native) return nil;
  libvlc_media_tracklist_t *list = libvlc_media_player_get_tracklist(_native, ESTrackType(type), false);
  if (!list) return nil;
  NSMutableArray *tracks = [NSMutableArray array];
  for (size_t i = 0; i < libvlc_media_tracklist_count(list); i++) {
    libvlc_media_track_t *track = libvlc_media_tracklist_at(list, i);
    if (!track->psz_id) continue;
    NSString *identifier = [NSString stringWithUTF8String:track->psz_id];
    if (!identifier) continue;
    NSString *name = track->psz_name ? [NSString stringWithUTF8String:track->psz_name] : nil;
    NSString *language = track->psz_language ? [NSString stringWithUTF8String:track->psz_language] : nil;
    [tracks addObject:@{ @"id": identifier, @"name": name ?: [NSNull null], @"language": language ?: [NSNull null], @"selected": @(track->selected) }];
  }
  libvlc_media_tracklist_delete(list);
  return tracks;
}
- (BOOL)selectTrackForType:(NSString *)type identifier:(NSString *)identifier {
  if (!_native) return NO;
  libvlc_track_type_t nativeType = ESTrackType(type);
  if (!identifier && nativeType == libvlc_track_text) {
    libvlc_media_player_unselect_track_type(_native, nativeType);
    return YES;
  }
  if (!identifier) return NO;
  libvlc_media_tracklist_t *list = libvlc_media_player_get_tracklist(_native, nativeType, false);
  if (!list) return NO;
  BOOL found = NO;
  for (size_t i = 0; i < libvlc_media_tracklist_count(list); i++) {
    libvlc_media_track_t *track = libvlc_media_tracklist_at(list, i);
    if (track->psz_id && [identifier isEqualToString:[NSString stringWithUTF8String:track->psz_id]]) {
      libvlc_media_player_select_track(_native, track);
      found = YES;
      break;
    }
  }
  libvlc_media_tracklist_delete(list);
  return found;
}
- (void)setListRepeatMode:(NSString *)mode {
  if (!_list) return;
  libvlc_media_list_player_set_playback_mode(_list, [mode isEqualToString:@"one"] ? libvlc_playback_mode_repeat : ([mode isEqualToString:@"all"] ? libvlc_playback_mode_loop : libvlc_playback_mode_default));
}
- (void)playListItemAtIndex:(NSUInteger)index { if (_list) libvlc_media_list_player_play_item_at_index(_list, (int)index); }
- (void)stopAsyncWithCompletion:(void (^)(void))completion { [self stop]; completion(); }
- (void)shutdown {
  if (_closed) return;
  _closed = YES;
  [self finishSeeks];
  self.mediaChanged = nil; self.stateChanged = nil; self.timeChanged = nil; self.seekFinished = nil; self.tracksChanged = nil; self.lengthChanged = nil;
  if (_native && _watchingTime) { libvlc_media_player_unwatch_time(_native); _watchingTime = NO; }
  if (_list) { libvlc_media_list_player_release(_list); _list = NULL; }
  if (_native) { libvlc_media_player_release(_native); _native = NULL; }
  for (NSValue *value in _nativeToMedia) libvlc_media_release(value.pointerValue);
  [_nativeToMedia removeAllObjects];
  [_mediaToNative removeAllObjects];
  _media = nil;
  _library = nil;
}
- (void)dealloc { [self shutdown]; }
@end
#endif
