#import <Foundation/Foundation.h>
#import <VLCKit/VLCKit.h>
#import <TargetConditionals.h>
#if TARGET_OS_IOS
NS_ASSUME_NONNULL_BEGIN
@interface ESVLCSessionOutput : NSObject
@property (nonatomic, readonly) void *nativePlayer;
@property (nonatomic, strong, readonly, nullable) VLCMedia *media;
@property (nonatomic, readonly) VLCMediaPlayerState state;
@property (nonatomic, readonly) BOOL isPlaying;
@property (nonatomic, readonly) BOOL isSeekable;
@property (nonatomic, readonly) int32_t positionMillis;
@property (nonatomic, readonly) int32_t durationMillis;
@property (nonatomic, copy, nullable) void (^mediaChanged)(VLCMedia *media);
@property (nonatomic, copy, nullable) void (^stateChanged)(void);
@property (nonatomic, copy, nullable) void (^timeChanged)(void);
@property (nonatomic, copy, nullable) void (^seekFinished)(void);
@property (nonatomic, copy, nullable) void (^tracksChanged)(void);
@property (nonatomic, copy, nullable) void (^lengthChanged)(int64_t length);
- (nullable instancetype)init;
- (nullable instancetype)initWithOptions:(nullable NSArray<NSString *> *)options;
- (void)setSubtitleFontScale:(float)scale;
- (BOOL)setPlaybackRate:(float)rate;
- (BOOL)setSoftwareVolume:(int)volume;
- (BOOL)setAudioDelayMillis:(int64_t)delayMillis NS_SWIFT_NAME(setAudioDelay(millis:));
- (BOOL)isPlayerStopped;
- (BOOL)nativeIsSeekable;
- (void)seekToPosition:(float)position fast:(BOOL)fast NS_SWIFT_NAME(seek(toPosition:fast:));
- (BOOL)jumpWithOffset:(int32_t)offset completion:(void (^)(void))completion NS_SWIFT_NAME(jump(withOffset:completion:));
- (void)play;
- (void)pause;
- (void)stop;
/** Stops automatic advancement by the list player. */
- (void)stopList NS_SWIFT_NAME(stopPlaylist());
- (void)stopAsyncWithCompletion:(void (^)(void))completion NS_SWIFT_NAME(stopAsync(completion:));
- (void)setMediaItems:(NSArray<VLCMedia *> *)items NS_SWIFT_NAME(setMediaItems(_:));
- (void)loadMedia:(VLCMedia *)media NS_SWIFT_NAME(loadMedia(_:));
- (nullable NSArray<NSDictionary<NSString *, id> *> *)tracksForType:(NSString *)type NS_SWIFT_NAME(tracks(for:));
- (BOOL)selectTrackForType:(NSString *)type identifier:(nullable NSString *)identifier NS_SWIFT_NAME(selectTrack(for:identifier:));
- (void)setListRepeatMode:(NSString *)mode NS_SWIFT_NAME(setListRepeatMode(_:));
- (void)playListItemAtIndex:(NSUInteger)index NS_SWIFT_NAME(playListItem(at:));
- (void)shutdown;
@end
NS_ASSUME_NONNULL_END
#endif
