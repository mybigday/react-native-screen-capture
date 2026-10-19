// Byte-exact extracted production lifecycle methods, executed with Foundation/CoreVideo.
// Session/item/output objects are AVFoundation boundary doubles; no UIKit or devices.
#import <Foundation/Foundation.h>
#import <CoreVideo/CoreVideo.h>
#import <os/lock.h>

@protocol AVCaptureVideoDataOutputSampleBufferDelegate <NSObject> @end
@interface AVCaptureOutput : NSObject @end
@implementation AVCaptureOutput @end
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
@property(nonatomic) BOOL allowed;
- (BOOL)canAddOutput:(AVCaptureOutput *)output;
- (void)beginConfiguration;
- (void)commitConfiguration;
- (void)addOutput:(AVCaptureOutput *)output;
- (void)removeOutput:(AVCaptureOutput *)output;
@end
@implementation AVCaptureSession
- (instancetype)init { if ((self = [super init])) _outputs = [NSMutableArray array]; return self; }
- (BOOL)canAddOutput:(AVCaptureOutput *)output { return self.allowed; }
- (void)beginConfiguration {}
- (void)commitConfiguration {}
- (void)addOutput:(AVCaptureOutput *)output { [self.outputs addObject:output]; }
- (void)removeOutput:(AVCaptureOutput *)output { [self.outputs removeObject:output]; }
@end
@interface AVPlayerItem : NSObject
@property(nonatomic, strong) NSMutableArray *outputs;
@property(nonatomic) BOOL failNextRemoval;
- (void)removeOutput:(id)output;
@end
@implementation AVPlayerItem
- (instancetype)init { if ((self = [super init])) { _outputs = [NSMutableArray array]; _failNextRemoval = YES; } return self; }
- (void)removeOutput:(id)output {
    if (self.failNextRemoval) { self.failNextRemoval = NO; [NSException raise:@"Injected" format:@"removeOutput failed"]; }
    [self.outputs removeObject:output];
}
@end
@interface HostDelegate : NSObject <AVCaptureVideoDataOutputSampleBufferDelegate> @end
@implementation HostDelegate @end
@interface CameraProbe : NSObject <AVCaptureVideoDataOutputSampleBufferDelegate> {
    __weak AVCaptureSession *_session;
    AVCaptureVideoDataOutput *_ownedOutput, *_borrowedOutput;
    __weak id<AVCaptureVideoDataOutputSampleBufferDelegate> _previousDelegate;
    dispatch_queue_t _previousQueue, _queue;
    os_unfair_lock _lock;
    CVPixelBufferRef _latest;
    BOOL _attached, _attachRefused;
    NSUInteger _attachmentGeneration;
}
- (instancetype)initWithSession:(AVCaptureSession *)session;
- (void)attach;
- (void)detach;
- (NSUInteger)attachmentGeneration;
@end
@implementation CameraProbe
// Single/unconnected legacy fixture only. Exact stream eligibility lives in CameraStreamProbe.
- (BOOL)matchesOutput:(AVCaptureVideoDataOutput *)output { return YES; }
- (BOOL)canCreateOutput { return YES; }
- (instancetype)initWithSession:(AVCaptureSession *)session {
    if ((self = [super init])) { _session = session; _lock = OS_UNFAIR_LOCK_INIT; _queue = dispatch_queue_create("provider-lifecycle", DISPATCH_QUEUE_SERIAL); }
    return self;
}
#include "CameraLifecycle.inc"
@end
@interface PlayerProbe : NSObject {
    __weak AVPlayerItem *_observedItem;
    id _output;
    os_unfair_lock _lock;
    CVPixelBufferRef _latest;
    BOOL _attached;
}
- (instancetype)initWithItem:(AVPlayerItem *)item output:(id)output buffer:(CVPixelBufferRef)buffer;
- (void)detach;
@end
@implementation PlayerProbe
- (instancetype)initWithItem:(AVPlayerItem *)item output:(id)output buffer:(CVPixelBufferRef)buffer {
    if ((self = [super init])) { _observedItem = item; _output = output; _latest = CVPixelBufferRetain(buffer); _attached = YES; _lock = OS_UNFAIR_LOCK_INIT; }
    return self;
}
#include "PlayerLifecycle.inc"
@end
static int checks, finalizations;
static void check(BOOL condition, NSString *message) { checks++; if (!condition) [NSException raise:@"TestFailure" format:@"%@", message]; }
static void releasePixels(void *context, const void *pixels) { finalizations++; free((void *)pixels); }
int main(void) { @autoreleasepool {
    @try {
        AVCaptureSession *refused = [AVCaptureSession new];
        CameraProbe *camera = [[CameraProbe alloc] initWithSession:refused];
        NSUInteger unchangedGeneration = camera.attachmentGeneration;
        for (int capture = 0; capture < 3; capture++) {
            [camera attach]; NSUInteger afterWait = camera.attachmentGeneration; [camera attach];
            check(camera.attachmentGeneration == afterWait, @"refused camera changes generation during final discovery");
            check(afterWait == unchangedGeneration, @"refused camera invalidates nonexistent hook");
            check(refused.outputs.count == 0, @"refused camera adds an output");
        }
        refused.allowed = YES; [camera attach];
        check(camera.attachmentGeneration != unchangedGeneration, @"successful retry fails to change generation");
        check(refused.outputs.count == 1, @"successful retry fails to add exactly one output");
        [camera detach]; check(refused.outputs.count == 0, @"camera cooldown leaves owned output attached");

        AVCaptureSession *borrowed = [AVCaptureSession new];
        HostDelegate *firstHost = [HostDelegate new], *secondHost = [HostDelegate new];
        AVCaptureVideoDataOutput *hostOutput = [AVCaptureVideoDataOutput new];
        dispatch_queue_t firstQueue = dispatch_queue_create("first-host", DISPATCH_QUEUE_SERIAL);
        dispatch_queue_t secondQueue = dispatch_queue_create("second-host", DISPATCH_QUEUE_SERIAL);
        [hostOutput setSampleBufferDelegate:firstHost queue:firstQueue]; [borrowed.outputs addObject:hostOutput];
        CameraProbe *shared = [[CameraProbe alloc] initWithSession:borrowed]; [shared attach];
        NSUInteger beforeReplacement = shared.attachmentGeneration;
        [hostOutput setSampleBufferDelegate:secondHost queue:secondQueue]; [shared attach];
        check(shared.attachmentGeneration != beforeReplacement, @"reacquired delegate fails to invalidate readiness");
        [shared detach];
        check(hostOutput.sampleBufferDelegate == secondHost && hostOutput.sampleBufferCallbackQueue == secondQueue,
              @"cooldown loses replacement host delegate or queue");

        AVPlayerItem *item = [AVPlayerItem new]; NSObject *owned = [NSObject new]; [item.outputs addObject:owned];
        CVPixelBufferRef buffer = NULL; void *pixels = calloc(8 * 4, 4);
        check(CVPixelBufferCreateWithBytes(kCFAllocatorDefault, 8, 4, kCVPixelFormatType_32BGRA, pixels, 8 * 4,
              releasePixels, NULL, NULL, &buffer) == kCVReturnSuccess, @"buffer allocation failed");
        PlayerProbe *player = [[PlayerProbe alloc] initWithItem:item output:owned buffer:buffer]; CVPixelBufferRelease(buffer);
        int before = finalizations; BOOL threw = NO;
        @try { [player detach]; } @catch (NSException *failure) { threw = YES; }
        check(threw, @"injected removal failure is swallowed");
        check(finalizations == before + 1, @"failed detach retains cached buffer");
        check([item.outputs containsObject:owned], @"fault unexpectedly removed output");
        [player detach]; check(![item.outputs containsObject:owned], @"detach retry leaves player output attached");
        [player detach]; check(finalizations == before + 1, @"repeated detach releases buffer twice");
        printf("{\"checks\":%d,\"passed\":true}\n", checks); return 0;
    } @catch (NSException *failure) { fprintf(stderr, "%s\n", failure.reason.UTF8String); return 1; }
} }
