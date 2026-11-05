#import "ESVLCSessionFrames.h"
#if TARGET_OS_IOS
#import <VLCKit/vlc/vlc.h>
#import <pthread.h>
#import <stdatomic.h>
#import <stdbool.h>
#import <stdlib.h>
#import <string.h>

typedef struct {
  pthread_mutex_t mutex;
  uint8_t *pixels;
  unsigned width, height, pitch;
  void *owner;
} ESFrameContext;

@interface ESVLCSessionFrames ()
- (void)present:(ESFrameContext *)context;
@end

static unsigned ESFormat(void **opaque, char *chroma, unsigned *width, unsigned *height, unsigned *pitches, unsigned *lines) {
  ESFrameContext *ctx = *opaque;
  unsigned w = width[1], h = height[1];
  if (!w || !h) return 0;
  double scale = MIN(1.0, 1280.0 / MAX(w, h));
  w = MAX(2u, ((unsigned)(w * scale) + 1u) & ~1u);
  h = MAX(2u, ((unsigned)(h * scale) + 1u) & ~1u);
  unsigned pitch = (w * 4 + 31u) & ~31u;
  unsigned rows = (h + 31u) & ~31u;
  void *pixels = NULL;
  if (posix_memalign(&pixels, 32, (size_t)pitch * rows) != 0) return 0;
  memset(pixels, 0, (size_t)pitch * rows);
  pthread_mutex_lock(&ctx->mutex);
  free(ctx->pixels);
  ctx->pixels = pixels; ctx->width = w; ctx->height = h; ctx->pitch = pitch;
  pthread_mutex_unlock(&ctx->mutex);
  // Match Core Video's kCVPixelFormatType_32BGRA byte order.
  memcpy(chroma, "BGRA", 4);
  width[0] = width[1] = w; height[0] = height[1] = h;
  pitches[0] = pitch; lines[0] = rows;
  return 1;
}
static void ESCleanup(void *opaque) { /* The next format or shutdown frees the buffer. */ }
static void *ESLock(void *opaque, void **planes) {
  ESFrameContext *ctx = opaque;
  pthread_mutex_lock(&ctx->mutex);
  *planes = ctx->pixels;
  return ctx;
}
static void ESUnlock(void *opaque, void *picture, void *const *planes) {
  pthread_mutex_unlock(&((ESFrameContext *)opaque)->mutex);
}
static void ESDisplay(void *opaque, void *picture) {
  ESFrameContext *ctx = opaque;
  [(__bridge ESVLCSessionFrames *)ctx->owner present:ctx];
}

@implementation ESVLCSessionFrames {
  ESFrameContext *_context;
  atomic_bool _pending;
  atomic_bool _running;
}
- (instancetype)initWithNativePlayer:(void *)nativePlayerPointer {
  if (!(self = [super init])) return nil;
  libvlc_media_player_t *nativePlayer = nativePlayerPointer;
  if (!nativePlayer) return nil;
  _context = calloc(1, sizeof(*_context));
  if (!_context) return nil;
  if (pthread_mutex_init(&_context->mutex, NULL) != 0) { free(_context); _context = NULL; return nil; }
  _context->owner = (__bridge void *)self;
  _displayLayer = [AVSampleBufferDisplayLayer new];
  _displayLayer.videoGravity = AVLayerVideoGravityResizeAspect;
  atomic_init(&_pending, false);
  atomic_init(&_running, true);
  libvlc_video_set_callbacks(nativePlayer, ESLock, ESUnlock, ESDisplay, _context);
  libvlc_video_set_format_callbacks(nativePlayer, ESFormat, ESCleanup);
  return self;
}
- (void)present:(ESFrameContext *)ctx {
  if (!atomic_load_explicit(&_running, memory_order_acquire) || atomic_exchange_explicit(&_pending, true, memory_order_acq_rel)) return;
  CVPixelBufferRef pixel = NULL;
  pthread_mutex_lock(&ctx->mutex);
  unsigned w = ctx->width, h = ctx->height;
  NSDictionary *attrs = @{(id)kCVPixelBufferIOSurfacePropertiesKey: @{}};
  CVReturn result = ctx->pixels ? CVPixelBufferCreate(kCFAllocatorDefault, w, h, kCVPixelFormatType_32BGRA, (__bridge CFDictionaryRef)attrs, &pixel) : kCVReturnError;
  if (result == kCVReturnSuccess && pixel && CVPixelBufferLockBaseAddress(pixel, 0) == kCVReturnSuccess) {
    uint8_t *dest = CVPixelBufferGetBaseAddress(pixel);
    size_t stride = CVPixelBufferGetBytesPerRow(pixel);
    if (dest && stride >= w * 4) for (unsigned row = 0; row < h; row++) memcpy(dest + row * stride, ctx->pixels + row * ctx->pitch, w * 4);
    CVPixelBufferUnlockBaseAddress(pixel, 0);
  } else { if (pixel) CVPixelBufferRelease(pixel); pixel = NULL; }
  pthread_mutex_unlock(&ctx->mutex);
  CMVideoFormatDescriptionRef format = NULL;
  CMSampleBufferRef sample = NULL;
  if (pixel && CMVideoFormatDescriptionCreateForImageBuffer(kCFAllocatorDefault, pixel, &format) == noErr) {
    CMSampleTimingInfo timing = { kCMTimeInvalid, kCMTimeInvalid, kCMTimeInvalid };
    CMSampleBufferCreateReadyWithImageBuffer(kCFAllocatorDefault, pixel, format, &timing, &sample);
  }
  if (format) CFRelease(format);
  if (pixel) CVPixelBufferRelease(pixel);
  if (!sample) { atomic_store_explicit(&_pending, false, memory_order_release); return; }
  CFArrayRef attachments = CMSampleBufferGetSampleAttachmentsArray(sample, true);
  if (attachments && CFArrayGetCount(attachments)) CFDictionarySetValue((CFMutableDictionaryRef)CFArrayGetValueAtIndex(attachments, 0), kCMSampleAttachmentKey_DisplayImmediately, kCFBooleanTrue);
  dispatch_async(dispatch_get_main_queue(), ^{
    if (atomic_load_explicit(&self->_running, memory_order_acquire)) {
      if (self->_displayLayer.status == AVQueuedSampleBufferRenderingStatusFailed) [self->_displayLayer flush];
      if (self->_displayLayer.readyForMoreMediaData) [self->_displayLayer enqueueSampleBuffer:sample];
    }
    CFRelease(sample);
    atomic_store_explicit(&self->_pending, false, memory_order_release);
  });
}
- (NSData *)snapshotJPEG {
  ESFrameContext *ctx = _context;
  if (!ctx || !atomic_load_explicit(&_running, memory_order_acquire)) return nil;
  pthread_mutex_lock(&ctx->mutex);
  unsigned width = ctx->width, height = ctx->height, pitch = ctx->pitch;
  NSMutableData *bytes = width && height && ctx->pixels ? [NSMutableData dataWithLength:(size_t)width * height * 4] : nil;
  if (bytes) {
    uint8_t *destination = bytes.mutableBytes;
    for (unsigned row = 0; row < height; row++) memcpy(destination + (size_t)row * width * 4, ctx->pixels + (size_t)row * pitch, (size_t)width * 4);
  }
  pthread_mutex_unlock(&ctx->mutex);
  if (!bytes) return nil;
  CGDataProviderRef provider = CGDataProviderCreateWithCFData((__bridge CFDataRef)bytes);
  if (!provider) return nil;
  CGColorSpaceRef colorSpace = CGColorSpaceCreateDeviceRGB();
  CGImageRef image = CGImageCreate(width, height, 8, 32, (size_t)width * 4, colorSpace,
      kCGBitmapByteOrder32Little | kCGImageAlphaPremultipliedFirst, provider, NULL, false, kCGRenderingIntentDefault);
  CGColorSpaceRelease(colorSpace);
  CGDataProviderRelease(provider);
  if (!image) return nil;
  UIImage *frame = [UIImage imageWithCGImage:image];
  CGImageRelease(image);
  return UIImageJPEGRepresentation(frame, 0.88);
}
- (void)shutdown {
  if (!_context) return;
  atomic_store_explicit(&_running, false, memory_order_release);
  // The player is stopped and will not be restarted. LibVLC requires non-null
  // callbacks, so do not attempt to clear them using unsupported NULL values.
  free(_context->pixels);
  pthread_mutex_destroy(&_context->mutex);
  free(_context);
  _context = NULL;
  [_displayLayer flushAndRemoveImage];
}
@end
#endif
