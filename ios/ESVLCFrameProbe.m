#import "ESVLCFrameProbe.h"

#if TARGET_OS_IOS
#import <VLCKit/VLCKit.h>
#import <VLCKit/vlc/vlc.h>
#import <pthread.h>
#import <stdatomic.h>
#import <stdbool.h>
#import <stdlib.h>
#import <string.h>

// Fixed-size memory output is for feasibility testing, not production playback.
typedef struct {
  pthread_mutex_t mutex;
  void *pixels;
  atomic_ulong frames;
  void *owner;
} ESProbeContext;

@interface ESVLCFrameProbe ()
- (void)presentFrameFromContext:(ESProbeContext *)context;
@end

static void *ESProbeLock(void *opaque, void **planes) {
  ESProbeContext *context = opaque;
  pthread_mutex_lock(&context->mutex);
  *planes = context->pixels;
  return context;
}

static void ESProbeUnlock(void *opaque, void *picture, void *const *planes) {
  ESProbeContext *context = opaque;
  pthread_mutex_unlock(&context->mutex);
}

static void ESProbeDisplay(void *opaque, void *picture) {
  ESProbeContext *context = opaque;
  atomic_fetch_add_explicit(&context->frames, 1, memory_order_relaxed);
  ESVLCFrameProbe *probe = (__bridge ESVLCFrameProbe *)context->owner;
  [probe presentFrameFromContext:context];
}

@implementation ESVLCFrameProbe {
  libvlc_media_player_t *_player;
  ESProbeContext *_context;
  AVSampleBufferDisplayLayer *_displayLayer;
  atomic_bool _framePending;
  atomic_bool _running;
}

+ (int)parseMedia:(VLCMedia *)media options:(int)options timeout:(int)timeout {
  return [[VLCMediaParser sharedParser] queueMedia:media options:VLCMediaParse];
}
+ (void)cancelParsingMedia:(VLCMedia *)media { [[VLCMediaParser sharedParser] cancelParsingForMedia:media]; }

- (instancetype)initWithDisplayLayer:(AVSampleBufferDisplayLayer *)displayLayer {
  self = [super init];
  if (self) {
    _displayLayer = displayLayer;
    atomic_init(&_framePending, false);
    atomic_init(&_running, false);
  }
  return self;
}

- (void)presentFrameFromContext:(ESProbeContext *)context {
  if (atomic_exchange_explicit(&_framePending, true, memory_order_acq_rel)) return;
  CVPixelBufferRef pixelBuffer = NULL;
  NSDictionary *attributes = @{ (id)kCVPixelBufferIOSurfacePropertiesKey: @{} };
  CVReturn result = CVPixelBufferCreate(kCFAllocatorDefault, 640, 360,
                                       kCVPixelFormatType_32BGRA,
                                       (__bridge CFDictionaryRef)attributes, &pixelBuffer);
  if (result != kCVReturnSuccess || pixelBuffer == NULL) {
    atomic_store_explicit(&_framePending, false, memory_order_release);
    return;
  }
  if (CVPixelBufferLockBaseAddress(pixelBuffer, 0) != kCVReturnSuccess) {
    CVPixelBufferRelease(pixelBuffer);
    atomic_store_explicit(&_framePending, false, memory_order_release);
    return;
  }
  uint8_t *destination = CVPixelBufferGetBaseAddress(pixelBuffer);
  size_t stride = CVPixelBufferGetBytesPerRow(pixelBuffer);
  if (destination == NULL || stride < 640 * 4) {
    CVPixelBufferUnlockBaseAddress(pixelBuffer, 0);
    CVPixelBufferRelease(pixelBuffer);
    atomic_store_explicit(&_framePending, false, memory_order_release);
    return;
  }
  pthread_mutex_lock(&context->mutex);
  for (size_t row = 0; row < 360; row++) {
    memcpy(destination + row * stride, (uint8_t *)context->pixels + row * 640 * 4, 640 * 4);
  }
  pthread_mutex_unlock(&context->mutex);
  CVPixelBufferUnlockBaseAddress(pixelBuffer, 0);

  CMVideoFormatDescriptionRef format = NULL;
  CMSampleBufferRef sample = NULL;
  OSStatus status = CMVideoFormatDescriptionCreateForImageBuffer(kCFAllocatorDefault, pixelBuffer, &format);
  if (status == noErr) {
    CMSampleTimingInfo timing = { .duration = kCMTimeInvalid, .presentationTimeStamp = kCMTimeInvalid, .decodeTimeStamp = kCMTimeInvalid };
    status = CMSampleBufferCreateReadyWithImageBuffer(kCFAllocatorDefault, pixelBuffer, format, &timing, &sample);
  }
  if (format) CFRelease(format);
  CVPixelBufferRelease(pixelBuffer);
  if (status != noErr || sample == NULL) {
    atomic_store_explicit(&_framePending, false, memory_order_release);
    return;
  }
  CFArrayRef attachments = CMSampleBufferGetSampleAttachmentsArray(sample, true);
  if (!attachments || CFArrayGetCount(attachments) == 0) {
    CFRelease(sample);
    atomic_store_explicit(&_framePending, false, memory_order_release);
    return;
  }
  CFMutableDictionaryRef entry = (CFMutableDictionaryRef)CFArrayGetValueAtIndex(attachments, 0);
  CFDictionarySetValue(entry, kCMSampleAttachmentKey_DisplayImmediately, kCFBooleanTrue);
  dispatch_async(dispatch_get_main_queue(), ^{
    if (atomic_load_explicit(&self->_running, memory_order_acquire)) {
      if (self->_displayLayer.status == AVQueuedSampleBufferRenderingStatusFailed) [self->_displayLayer flush];
      if (self->_displayLayer.readyForMoreMediaData) [self->_displayLayer enqueueSampleBuffer:sample];
    }
    CFRelease(sample);
    atomic_store_explicit(&self->_framePending, false, memory_order_release);
  });
}

- (NSString *)startURL:(NSURL *)url {
  if (_player != NULL) return @"A frame probe is already running";
  if (!url.isFileURL) return @"The frame probe requires a local file URL";
  VLCLibrary *library = [VLCLibrary sharedLibrary];
  libvlc_instance_t *instance = (libvlc_instance_t *)library.instance;
  if (instance == NULL) return @"The LibVLC instance is unavailable";

  ESProbeContext *context = calloc(1, sizeof(*context));
  if (context == NULL) return @"Could not allocate the frame probe";
  if (pthread_mutex_init(&context->mutex, NULL) != 0) {
    free(context);
    return @"Could not initialize the frame probe lock";
  }
  if (posix_memalign(&context->pixels, 32, 640 * 360 * 4) != 0) {
    pthread_mutex_destroy(&context->mutex);
    free(context);
    return @"Could not allocate the frame buffer";
  }
  atomic_init(&context->frames, 0);
  context->owner = (__bridge void *)self;
  libvlc_media_player_t *player = libvlc_media_player_new(instance, NULL, NULL);
  if (player == NULL) {
    free(context->pixels);
    pthread_mutex_destroy(&context->mutex);
    free(context);
    return @"Could not create the frame probe player";
  }
  libvlc_media_t *media = libvlc_media_new_location(url.absoluteString.UTF8String);
  if (media == NULL) {
    libvlc_media_player_release(player);
    free(context->pixels);
    pthread_mutex_destroy(&context->mutex);
    free(context);
    return @"Could not create the frame probe media";
  }
  libvlc_video_set_callbacks(player, ESProbeLock, ESProbeUnlock, ESProbeDisplay, context);
  // Match Core Video's kCVPixelFormatType_32BGRA byte order.
  libvlc_video_set_format(player, "BGRA", 640, 360, 640 * 4);
  libvlc_media_add_option(media, ":no-audio");
  libvlc_media_player_set_media(player, media);
  libvlc_media_release(media);
  libvlc_audio_set_mute(player, 1);
  _context = context;
  _player = player;
  atomic_store_explicit(&_running, true, memory_order_release);
  dispatch_async(dispatch_get_main_queue(), ^{ [self->_displayLayer flushAndRemoveImage]; });
  if (libvlc_media_player_play(player) != 0) {
    [self stop];
    return @"The frame probe player could not start";
  }
  return nil;
}

- (NSUInteger)frameCount {
  return _context == NULL ? 0 : (NSUInteger)atomic_load_explicit(&_context->frames, memory_order_relaxed);
}

- (BOOL)isPlaying { return _player != NULL && libvlc_media_player_is_playing(_player) != 0; }
- (int64_t)positionMillis { return _player == NULL ? 0 : MAX(0, libvlc_media_player_get_time(_player) / 1000); }
- (int64_t)durationMillis { return _player == NULL ? 0 : MAX(0, libvlc_media_player_get_length(_player) / 1000); }
- (void)setPlaying:(BOOL)playing {
  if (_player == NULL) return;
  if (playing && libvlc_media_player_get_state(_player) == libvlc_Stopped) libvlc_media_player_play(_player);
  else libvlc_media_player_set_pause(_player, playing ? 0 : 1);
}
- (void)seekToMillis:(int64_t)millis {
  if (_player != NULL) libvlc_media_player_set_time(_player, MAX(0, millis) * 1000, true);
}

- (void)stop {
  atomic_store_explicit(&_running, false, memory_order_release);
  if (_player != NULL) {
    // Synchronous stop completes before freeing the callback context.
    if (libvlc_media_player_stop_async(_player) == 0) {
      while (libvlc_media_player_get_state(_player) != libvlc_Stopped) { [NSThread sleepForTimeInterval:0.01]; }
    }
    libvlc_media_player_release(_player);
    _player = NULL;
  }
  if (_context != NULL) {
    free(_context->pixels);
    pthread_mutex_destroy(&_context->mutex);
    free(_context);
    _context = NULL;
  }
}

- (void)dealloc { [self stop]; }
@end
#endif
