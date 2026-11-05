#import <Foundation/Foundation.h>
#import <AVFoundation/AVFoundation.h>
#import <UIKit/UIKit.h>
#import <VLCKit/VLCKit.h>
#import <TargetConditionals.h>
#if TARGET_OS_IOS
NS_ASSUME_NONNULL_BEGIN
@interface ESVLCSessionFrames : NSObject
@property (nonatomic, readonly) AVSampleBufferDisplayLayer *displayLayer;
// Accepts a LibVLC player owned by the caller and kept alive until shutdown.
- (nullable instancetype)initWithNativePlayer:(void *)nativePlayer;
// Returns the latest decoded frame as JPEG data, or nil before the first frame.
- (nullable NSData *)snapshotJPEG;
// Call only after the player has completely stopped.
- (void)shutdown;
@end
NS_ASSUME_NONNULL_END
#endif
