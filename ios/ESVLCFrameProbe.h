#import <Foundation/Foundation.h>
#import <AVFoundation/AVFoundation.h>
#import <TargetConditionals.h>

#if TARGET_OS_IOS
NS_ASSUME_NONNULL_BEGIN
@class VLCMedia;

/// Independent, muted experiment for observing LibVLC decoded-frame callbacks.
@interface ESVLCFrameProbe : NSObject
+ (int)parseMedia:(VLCMedia *)media options:(int)options timeout:(int)timeout NS_SWIFT_NAME(parseMedia(_:options:timeout:));
+ (void)cancelParsingMedia:(VLCMedia *)media NS_SWIFT_NAME(cancelParsingMedia(_:));
- (instancetype)initWithDisplayLayer:(AVSampleBufferDisplayLayer *)displayLayer;
- (nullable NSString *)startURL:(NSURL *)url NS_SWIFT_NAME(start(url:));
- (NSUInteger)frameCount;
- (BOOL)isPlaying;
- (int64_t)positionMillis;
- (int64_t)durationMillis;
- (void)setPlaying:(BOOL)playing;
- (void)seekToMillis:(int64_t)millis;
- (void)stop;
@end

NS_ASSUME_NONNULL_END
#endif
