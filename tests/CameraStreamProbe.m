#import <Foundation/Foundation.h>
#import <CoreVideo/CoreVideo.h>
#import <CoreMedia/CoreMedia.h>
#import <os/lock.h>

static NSString *const AVMediaTypeVideo = @"video";
@interface AVCaptureInputPort : NSObject
@property(nonatomic, copy) NSString *mediaType;
@end
@implementation AVCaptureInputPort @end
@interface AVCaptureConnection : NSObject
@property(nonatomic, copy) NSArray<AVCaptureInputPort *> *inputPorts;
@end
@implementation AVCaptureConnection @end
@class AVCaptureOutput;
@protocol AVCaptureVideoDataOutputSampleBufferDelegate <NSObject>
@optional
- (void)captureOutput:(AVCaptureOutput *)output didOutputSampleBuffer:(CMSampleBufferRef)sample fromConnection:(AVCaptureConnection *)connection;
@end
@interface AVCaptureOutput : NSObject
@property(nonatomic, copy) NSArray<AVCaptureConnection *> *connections;
@end
@implementation AVCaptureOutput
- (instancetype)init { if ((self = [super init])) _connections = @[]; return self; }
@end
@interface AVCaptureVideoDataOutput : AVCaptureOutput
@property(nonatomic, weak) id<AVCaptureVideoDataOutputSampleBufferDelegate> sampleBufferDelegate;
@property(nonatomic, strong) dispatch_queue_t sampleBufferCallbackQueue;
@property(nonatomic) BOOL alwaysDiscardsLateVideoFrames;
@property(nonatomic, copy) NSDictionary *videoSettings;
- (void)setSampleBufferDelegate:(id<AVCaptureVideoDataOutputSampleBufferDelegate>)delegate queue:(dispatch_queue_t)queue;
@end
@implementation AVCaptureVideoDataOutput
- (void)setSampleBufferDelegate:(id<AVCaptureVideoDataOutputSampleBufferDelegate>)delegate queue:(dispatch_queue_t)queue {
    self.sampleBufferDelegate = delegate; self.sampleBufferCallbackQueue = queue;
}
@end
@interface AVCaptureSession : NSObject
@property(nonatomic, strong) NSMutableArray<AVCaptureOutput *> *outputs;
@property(nonatomic, copy) NSArray *inputs;
- (BOOL)canAddOutput:(AVCaptureOutput *)output;
- (void)beginConfiguration;
- (void)commitConfiguration;
- (void)addOutput:(AVCaptureOutput *)output;
- (void)removeOutput:(AVCaptureOutput *)output;
@end
@implementation AVCaptureSession
- (instancetype)init { if ((self = [super init])) { _outputs = [NSMutableArray array]; _inputs = @[]; } return self; }
- (BOOL)canAddOutput:(AVCaptureOutput *)output { return YES; }
- (void)beginConfiguration {}
- (void)commitConfiguration {}
- (void)addOutput:(AVCaptureOutput *)output { [self.outputs addObject:output]; }
- (void)removeOutput:(AVCaptureOutput *)output { [self.outputs removeObject:output]; }
@end
@interface AVCaptureMultiCamSession : AVCaptureSession @end
@implementation AVCaptureMultiCamSession @end
@interface AVCaptureVideoPreviewLayer : NSObject
@property(nonatomic, strong) AVCaptureSession *session;
@property(nonatomic, strong) AVCaptureConnection *connection;
@end
@implementation AVCaptureVideoPreviewLayer @end
@interface SwitchingPreview : AVCaptureVideoPreviewLayer
@property(nonatomic, strong) AVCaptureConnection *firstConnection;
@property(nonatomic, strong) AVCaptureConnection *laterConnection;
@property(nonatomic) NSUInteger connectionReads;
@end
@implementation SwitchingPreview
- (AVCaptureConnection *)connection {
    return self.connectionReads++ == 0 ? self.firstConnection : self.laterConnection;
}
@end
@interface HostDelegate : NSObject <AVCaptureVideoDataOutputSampleBufferDelegate>
@property(nonatomic) NSUInteger samples;
@end
@implementation HostDelegate
- (void)captureOutput:(AVCaptureOutput *)output didOutputSampleBuffer:(CMSampleBufferRef)sample fromConnection:(AVCaptureConnection *)connection { self.samples++; }
@end
#include "CameraStreamHelpers.inc"
@class UIView;
@interface CameraStreamProbe : NSObject <AVCaptureVideoDataOutputSampleBufferDelegate> {
    __weak AVCaptureSession *_session;
    __weak AVCaptureVideoPreviewLayer *_previewLayer;
    __weak UIView *_targetView;
    AVCaptureVideoDataOutput *_ownedOutput, *_borrowedOutput;
    __weak id<AVCaptureVideoDataOutputSampleBufferDelegate> _previousDelegate;
    dispatch_queue_t _previousQueue, _queue;
    os_unfair_lock _lock;
    CVPixelBufferRef _latest;
    BOOL _attached, _attachRefused, _multiCam;
    NSString *_streamIdentity, *_identifier;
    NSUInteger _attachmentGeneration;
}
- (instancetype)initWithPreview:(AVCaptureVideoPreviewLayer *)preview;
- (nullable instancetype)initWithPreviewLayer:(AVCaptureVideoPreviewLayer *)preview targetView:(UIView *)view;
- (void)attach;
- (void)detach;
- (BOOL)hasFrame;
- (NSUInteger)attachmentGeneration;
@property(nonatomic, copy, readonly) NSString *identifier;
#if RNSC_HAS_STREAM_HELPERS
+ (NSString *)sourceIdentifierForPreview:(AVCaptureVideoPreviewLayer *)preview;
- (BOOL)matchesPreview:(AVCaptureVideoPreviewLayer *)preview;
- (BOOL)matchesConnection:(AVCaptureConnection *)connection;
- (BOOL)matchesOutput:(AVCaptureVideoDataOutput *)output;
- (BOOL)canCreateOutput;
#endif
- (NSUInteger)pixelRGB;
@end
@implementation CameraStreamProbe
@synthesize identifier = _identifier;
- (instancetype)initWithPreview:(AVCaptureVideoPreviewLayer *)preview {
    return [self initWithPreviewLayer:preview targetView:nil];
}
- (NSUInteger)pixelRGB {
    if (!_latest) return NSUIntegerMax;
    CVPixelBufferLockBaseAddress(_latest, kCVPixelBufferLock_ReadOnly);
    const uint8_t *pixel = CVPixelBufferGetBaseAddress(_latest);
    NSUInteger color = (pixel[2] << 16) | (pixel[1] << 8) | pixel[0];
    CVPixelBufferUnlockBaseAddress(_latest, kCVPixelBufferLock_ReadOnly); return color;
}
#include "CameraStreamMethods.inc"
@end
@interface CameraSourceStoreProbe : NSObject {
    NSMapTable *_cameraSources;
}
- (void)store:(CameraStreamProbe *)source key:(NSString *)sourceKey;
- (id)readerForKey:(NSString *)key;
@end
@implementation CameraSourceStoreProbe
- (instancetype)init { if ((self = [super init])) _cameraSources = [NSMapTable strongToWeakObjectsMapTable]; return self; }
- (void)store:(CameraStreamProbe *)source key:(NSString *)sourceKey {
#include "CameraSourceStore.inc"
}
- (id)readerForKey:(NSString *)key { return [_cameraSources objectForKey:key]; }
@end
static NSUInteger checks, sampleAllocations, sampleFinalizations;
static void check(BOOL value, NSString *message) { checks++; if (!value) [NSException raise:@"TestFailure" format:@"%@", message]; }
static AVCaptureConnection *connection(AVCaptureInputPort *port) {
    AVCaptureConnection *result = [AVCaptureConnection new]; result.inputPorts = @[port]; return result;
}
static AVCaptureVideoPreviewLayer *preview(AVCaptureSession *session, AVCaptureConnection *connection) {
    AVCaptureVideoPreviewLayer *result = [AVCaptureVideoPreviewLayer new]; result.session = session; result.connection = connection; return result;
}
static void releasePixels(void *context, const void *pixels) { sampleFinalizations++; free((void *)pixels); }
static void feed(AVCaptureVideoDataOutput *output, AVCaptureConnection *connection, NSUInteger rgb) {
    CVPixelBufferRef buffer = NULL;
    void *pixels = calloc(8 * 4, 4); sampleAllocations++;
    check(CVPixelBufferCreateWithBytes(kCFAllocatorDefault, 8, 4, kCVPixelFormatType_32BGRA,
          pixels, 8 * 4, releasePixels, NULL, NULL, &buffer) == kCVReturnSuccess, @"pixel allocation");
    CVPixelBufferLockBaseAddress(buffer, 0);
    uint8_t *bytes = CVPixelBufferGetBaseAddress(buffer); bytes[0] = rgb & 255; bytes[1] = (rgb >> 8) & 255; bytes[2] = (rgb >> 16) & 255; bytes[3] = 255;
    CVPixelBufferUnlockBaseAddress(buffer, 0);
    CMVideoFormatDescriptionRef format = NULL; CMSampleBufferRef sample = NULL;
    check(CMVideoFormatDescriptionCreateForImageBuffer(kCFAllocatorDefault, buffer, &format) == noErr, @"sample format");
    CMSampleTimingInfo timing = {CMTimeMake(1, 30), kCMTimeZero, kCMTimeInvalid};
    check(CMSampleBufferCreateReadyWithImageBuffer(kCFAllocatorDefault, buffer, format, &timing, &sample) == noErr, @"sample allocation");
    id<AVCaptureVideoDataOutputSampleBufferDelegate> delegate = output.sampleBufferDelegate;
    [delegate captureOutput:output didOutputSampleBuffer:sample fromConnection:connection];
    CFRelease(sample); CFRelease(format); CVPixelBufferRelease(buffer);
}
int main(void) { @autoreleasepool { @try {
    AVCaptureInputPort *front = [AVCaptureInputPort new], *back = [AVCaptureInputPort new]; front.mediaType = back.mediaType = AVMediaTypeVideo;
    AVCaptureConnection *frontConnection = connection(front), *backConnection = connection(back);
    AVCaptureMultiCamSession *session = [AVCaptureMultiCamSession new]; session.inputs = @[[NSObject new], [NSObject new]];
    HostDelegate *frontHost = [HostDelegate new], *backHost = [HostDelegate new];
    dispatch_queue_t frontQueue = dispatch_queue_create("front", DISPATCH_QUEUE_SERIAL), backQueue = dispatch_queue_create("back", DISPATCH_QUEUE_SERIAL);
    AVCaptureVideoDataOutput *frontOutput = [AVCaptureVideoDataOutput new], *backOutput = [AVCaptureVideoDataOutput new];
    frontOutput.connections = @[frontConnection]; backOutput.connections = @[backConnection];
    [frontOutput setSampleBufferDelegate:frontHost queue:frontQueue]; [backOutput setSampleBufferDelegate:backHost queue:backQueue];
    [session.outputs addObjectsFromArray:@[frontOutput, backOutput]];
    AVCaptureVideoPreviewLayer *frontPreview = preview(session, frontConnection), *backPreview = preview(session, backConnection);
    CameraStreamProbe *frontReader = [[CameraStreamProbe alloc] initWithPreview:frontPreview], *backReader = [[CameraStreamProbe alloc] initWithPreview:backPreview];
    [frontReader attach]; [backReader attach]; feed(frontOutput, frontConnection, 0xff0000); feed(backOutput, backConnection, 0x00ff00);
    check(frontReader.pixelRGB == 0xff0000, @"front preview got wrong pixels");
    check(backReader.pixelRGB == 0x00ff00, @"back preview got front pixels");
    check(frontHost.samples == 1 && backHost.samples == 1, @"host callbacks changed");
#if RNSC_HAS_STREAM_HELPERS
    AVCaptureVideoPreviewLayer *frontAgain = preview(session, connection(front));
    check([[CameraStreamProbe sourceIdentifierForPreview:frontPreview] isEqualToString:[CameraStreamProbe sourceIdentifierForPreview:frontAgain]], @"same stream readers do not dedup");
    check(![[CameraStreamProbe sourceIdentifierForPreview:frontPreview] isEqualToString:[CameraStreamProbe sourceIdentifierForPreview:backPreview]], @"different streams share reader key");
    SwitchingPreview *switching = [SwitchingPreview new]; switching.session = session;
    switching.firstConnection = frontConnection; switching.laterConnection = backConnection;
    CameraStreamProbe *snapshot = [[CameraStreamProbe alloc] initWithPreview:switching];
    check(![snapshot matchesPreview:switching], @"constructor stream snapshot silently changes identity");
    SwitchingPreview *factorySwitch = [SwitchingPreview new]; factorySwitch.session = session;
    factorySwitch.firstConnection = frontConnection; factorySwitch.laterConnection = backConnection;
    NSString *discoveredKey = [CameraStreamProbe sourceIdentifierForPreview:factorySwitch];
    CameraStreamProbe *factoryReader = [[CameraStreamProbe alloc] initWithPreview:factorySwitch];
    CameraSourceStoreProbe *readerStore = [CameraSourceStoreProbe new]; [readerStore store:factoryReader key:discoveredKey];
    check([readerStore readerForKey:[CameraStreamProbe sourceIdentifierForPreview:factorySwitch]] == factoryReader,
          @"reader stored under pre-construction stream key");
    frontAgain.connection = backConnection;
    check(![frontReader matchesPreview:frontAgain], @"presentation stream change stays alive");
    NSUInteger beforeDrop = sampleFinalizations;
    feed(frontOutput, backConnection, 0x00ff00);
    check(frontReader.pixelRGB == 0xff0000, @"wrong-connection callback publishes wrong stream");
    check(sampleFinalizations == beforeDrop + 1, @"wrong-connection callback retains discarded sample");
    NSUInteger beforeReroute = frontReader.attachmentGeneration;
    frontOutput.connections = @[backConnection]; [frontReader attach];
    check(!frontReader.hasFrame && frontReader.attachmentGeneration != beforeReroute,
          @"output reroute leaves stale frame/readiness");
    check(frontOutput.sampleBufferDelegate == frontHost, @"output reroute does not restore host delegate");
    frontOutput.connections = @[frontConnection];
#endif
    [frontReader detach]; [backReader detach];
    check(frontOutput.sampleBufferDelegate == frontHost && frontOutput.sampleBufferCallbackQueue == frontQueue, @"front delegate/queue restoration");
    check(backOutput.sampleBufferDelegate == backHost && backOutput.sampleBufferCallbackQueue == backQueue, @"back delegate/queue restoration");
    CameraStreamProbe *unknown = [[CameraStreamProbe alloc] initWithPreview:preview(session, nil)]; [unknown attach];
    check(frontOutput.sampleBufferDelegate == frontHost && backOutput.sampleBufferDelegate == backHost && !unknown.hasFrame, @"ambiguous MultiCam borrows a live stream"); [unknown detach];
    [session.outputs removeObject:backOutput];
    CameraStreamProbe *missing = [[CameraStreamProbe alloc] initWithPreview:backPreview]; [missing attach];
    check(session.outputs.count == 1 && frontOutput.sampleBufferDelegate == frontHost && !missing.hasFrame, @"missing stream adds or borrows unrelated output"); [missing detach];
    frontOutput.connections = @[frontConnection, backConnection];
    CameraStreamProbe *mixed = [[CameraStreamProbe alloc] initWithPreview:frontPreview]; [mixed attach];
    check(frontOutput.sampleBufferDelegate == frontHost && session.outputs.count == 1, @"mixed-stream output borrowed"); [mixed detach];
    AVCaptureSession *ordinary = [AVCaptureSession new];
    AVCaptureVideoDataOutput *ordinaryOutput = [AVCaptureVideoDataOutput new]; ordinaryOutput.connections = @[frontConnection];
    [ordinaryOutput setSampleBufferDelegate:frontHost queue:frontQueue]; [ordinary.outputs addObject:ordinaryOutput];
    AVCaptureVideoPreviewLayer *unidentifiedPreview = preview(ordinary, nil);
    CameraStreamProbe *unidentifiedReader = [[CameraStreamProbe alloc] initWithPreview:unidentifiedPreview]; [unidentifiedReader attach];
    check(ordinary.outputs.count == 1 && ordinaryOutput.sampleBufferDelegate == frontHost && !unidentifiedReader.hasFrame,
          @"unidentified ordinary preview borrows identifiable stream"); [unidentifiedReader detach];
    unidentifiedPreview.connection = frontConnection;
    CameraStreamProbe *identifiedReader = [[CameraStreamProbe alloc] initWithPreview:unidentifiedPreview]; [identifiedReader attach];
    feed(ordinaryOutput, frontConnection, 0xff0000);
    check(identifiedReader.pixelRGB == 0xff0000, @"identifiable ordinary preview fails to recover"); [identifiedReader detach];
    check(ordinaryOutput.sampleBufferDelegate == frontHost && ordinaryOutput.sampleBufferCallbackQueue == frontQueue,
          @"ordinary recovery loses host delegate/queue");
    AVCaptureMultiCamSession *synthetic = [AVCaptureMultiCamSession new];
    AVCaptureVideoPreviewLayer *syntheticPreview = preview(synthetic, nil);
    CameraStreamProbe *legacy = [[CameraStreamProbe alloc] initWithPreview:syntheticPreview]; [legacy attach];
    check(synthetic.outputs.count == 1, @"inputless/no-connection owned fallback lost"); [legacy detach]; check(synthetic.outputs.count == 0, @"synthetic owned output leaks");
    AVCaptureVideoDataOutput *syntheticOutput = [AVCaptureVideoDataOutput new]; [synthetic.outputs addObject:syntheticOutput]; [syntheticOutput setSampleBufferDelegate:frontHost queue:frontQueue];
    CameraStreamProbe *fanout = [[CameraStreamProbe alloc] initWithPreview:syntheticPreview]; [fanout attach]; feed(syntheticOutput, nil, 0x0000ff);
    check(fanout.pixelRGB == 0x0000ff, @"synthetic borrowed frame fallback lost"); [fanout detach];
    check(syntheticOutput.sampleBufferDelegate == frontHost && syntheticOutput.sampleBufferCallbackQueue == frontQueue, @"synthetic borrowed host restoration");
    check(sampleFinalizations == sampleAllocations, @"camera reader retains samples after teardown");
    printf("{\"checks\":%lu,\"passed\":true}\n", (unsigned long)checks); return 0;
} @catch (NSException *failure) { fprintf(stderr, "%s\n", failure.reason.UTF8String); return 1; } } }
