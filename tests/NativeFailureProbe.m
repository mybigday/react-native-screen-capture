#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>
#import <objc/runtime.h>
#import <CoreVideo/CoreVideo.h>
#import <os/lock.h>
#import "RNSCFileStore.h"
#import <math.h>
#include <sys/stat.h>

// Foundation execution of byte-exact production methods; these are codec/React stubs,
// not a UIKit screenshot or RN bridge/device test. Filesystem operations are real and small.
typedef void (^RCTPromiseResolveBlock)(id);
typedef void (^RCTPromiseRejectBlock)(NSString *, NSString *, NSError *);
static NSString *const kErrorCapture = @"E_CAPTURE";
static NSString *fault;
extern void RNSCCreateAutoreleasedSentinel(void);
extern NSUInteger RNSCAutoreleasedSentinelsAlive(void);
static NSError *RNSCExceptionError(NSException *exception) {
    return [NSError errorWithDomain:@"probe" code:500 userInfo:@{NSLocalizedDescriptionKey: exception.reason}];
}
@interface UIImage : NSObject
@property(nonatomic, readonly) CGImageRef CGImage;
@property(nonatomic, readonly) CGSize size;
@property(nonatomic, readonly) CGFloat scale;
@end
@implementation UIImage
- (CGImageRef)CGImage { return NULL; }
- (CGSize)size { return CGSizeMake(8, 4); }
- (CGFloat)scale { return 1; }
@end

@interface UIWindow : NSObject
@property(nonatomic) BOOL isKeyWindow;
@property(nonatomic) CGRect bounds;
@end
@implementation UIWindow @end

@interface FaultData : NSData
@property(nonatomic) NSUInteger writes;
@end
@implementation FaultData
- (NSUInteger)length { return 3; }
- (const void *)bytes { return "abc"; }
- (NSString *)base64EncodedStringWithOptions:(NSDataBase64EncodingOptions)options {
    if ([fault isEqual:@"base64_throws"]) [NSException raise:@"Injected" format:@"base64 failed"];
    return @"YWJj";
}
- (BOOL)writeToFile:(NSString *)path options:(NSDataWritingOptions)options error:(NSError **)error {
    self.writes++;
    if ([fault isEqual:@"disk_full"] || [fault isEqual:@"permission_denied"]) {
        *error = [NSError errorWithDomain:NSCocoaErrorDomain
            code:[fault isEqual:@"disk_full"] ? NSFileWriteOutOfSpaceError : NSFileWriteNoPermissionError
            userInfo:@{NSLocalizedDescriptionKey: fault}];
        return NO;
    }
    if ([fault isEqual:@"write_throws"]) [NSException raise:@"Injected" format:@"write failed"];
    if ([fault isEqual:@"cache_purged"] && self.writes == 1) {
        [NSFileManager.defaultManager removeItemAtPath:path.stringByDeletingLastPathComponent error:NULL];
        *error = [NSError errorWithDomain:NSCocoaErrorDomain code:NSFileNoSuchFileError userInfo:nil];
        return NO;
    }
    return [[NSData dataWithBytes:self.bytes length:self.length] writeToFile:path options:options error:error];
}
@end
static NSData *UIImageJPEGRepresentation(UIImage *image, CGFloat quality) {
    RNSCCreateAutoreleasedSentinel();
    if ([fault isEqual:@"jpeg_nil"]) return nil;
    if ([fault isEqual:@"codec_throws"]) [NSException raise:@"Injected" format:@"codec failed"];
    return [FaultData new];
}
static NSData *UIImagePNGRepresentation(UIImage *image) {
    if ([fault isEqual:@"png_nil"]) return nil;
    return UIImageJPEGRepresentation(image, 1);
}
@interface FaultManager : NSFileManager
@property(nonatomic) BOOL failList;
@end
@implementation FaultManager
- (NSArray *)contentsOfDirectoryAtPath:(NSString *)path error:(NSError **)error {
    if (self.failList) { *error = [NSError errorWithDomain:NSCocoaErrorDomain code:NSFileReadNoPermissionError userInfo:nil]; return nil; }
    return [super contentsOfDirectoryAtPath:path error:error];
}
@end
@interface FaultStore : RNSCFileStore @end
@implementation FaultStore
- (BOOL)releaseURI:(NSString *)uri error:(NSError **)error {
    if ([fault isEqual:@"cancel_cleanup_throws"]) [NSException raise:@"Injected" format:@"rollback threw"];
    return [super releaseURI:uri error:error];
}
@end
@interface EncodeProbe : NSObject
@property(nonatomic) NSUInteger finishCalls;
@property(nonatomic) NSUInteger cancellationChecks;
@end
@implementation EncodeProbe
- (UIImage *)scaleImage:(UIImage *)image by:(CGFloat)scale {
    if ([fault isEqual:@"scale_throws"]) [NSException raise:@"Injected" format:@"scale failed"];
    return image;
}
- (BOOL)isInvalidated {
    self.cancellationChecks++;
    return [fault hasPrefix:@"cancel_"] && self.cancellationChecks > 1;
}
- (void)finishCapture { self.finishCalls++; }
#include "EncodeCurrent.inc"
@end

@protocol RNSCFrameProvider <NSObject>
- (BOOL)hasFrame;
@end
static NSMutableArray *RNSCPendingOperations;
static BOOL RNSCOperationRunning;
static NSString *const kErrorDomain = @"probe";
static const NSInteger kMaxFrameWaitAttempts = 8;
static const NSTimeInterval kFrameWaitInterval = 0.001;
@interface RNSCWindowCapture : NSObject @end
@implementation RNSCWindowCapture
#include "SerialCurrent.inc"
#include "PrimaryCurrent.inc"
#include "WaitCurrent.inc"
@end
@interface WaitProvider : NSObject <RNSCFrameProvider>
@property(nonatomic) NSUInteger calls;
@end
@implementation WaitProvider
- (BOOL)hasFrame {
    if (++self.calls == 9) [NSException raise:@"Injected" format:@"terminal wait read failed"];
    return NO;
}
@end
// Real CoreVideo buffer lifetime; only conversion is stubbed to throw.
static CGImageRef RNSCCreateImageFromPixelBuffer(CVPixelBufferRef buffer) {
    [NSException raise:@"Injected" format:@"conversion failed"];
    return NULL;
}
@interface BufferProbe : NSObject {
@protected
    os_unfair_lock _lock;
    CVPixelBufferRef _latest;
}
- (instancetype)initWithBuffer:(CVPixelBufferRef)buffer;
- (void)pump;
- (void)detach;
- (CGImageRef)newFrameImage;
@end
@implementation BufferProbe
- (instancetype)initWithBuffer:(CVPixelBufferRef)buffer {
    if ((self = [super init])) { _lock = OS_UNFAIR_LOCK_INIT; _latest = CVPixelBufferRetain(buffer); }
    return self;
}
- (void)pump {}
- (void)detach { if (_latest) { CVPixelBufferRelease(_latest); _latest = NULL; } }
@end
@interface PlayerBufferProbe : BufferProbe @end
@implementation PlayerBufferProbe
#include "FramePlayer.inc"
@end
@interface CameraBufferProbe : BufferProbe @end
@implementation CameraBufferProbe
#include "FrameCamera.inc"
@end
@interface SampleBufferProbe : BufferProbe @end
@implementation SampleBufferProbe
#include "FrameSampleBuffer.inc"
@end
static int bufferFinalizations;
static void releasePixels(void *info, const void *base) { bufferFinalizations++; free((void *)base); }
static int checks;
static void checkAt(BOOL ok, int line) { checks++; if (!ok) [NSException raise:@"Assertion" format:@"check %d at line %d", checks, line]; }
#define check(...) checkAt((__VA_ARGS__), __LINE__)
static void pumpUntil(BOOL (^condition)(void)) {
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:2];
    while (!condition() && deadline.timeIntervalSinceNow > 0) {
        [NSRunLoop.currentRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.005]];
    }
    check(condition());
}
int main(void) { @autoreleasepool {
    NSString *root = [NSTemporaryDirectory() stringByAppendingPathComponent:[@"rnsc-fault-" stringByAppendingString:NSUUID.UUID.UUIDString]];
    NSFileManager *manager = NSFileManager.defaultManager;
    [manager createDirectoryAtPath:root withIntermediateDirectories:YES attributes:nil error:NULL];
    __block RNSCFileStore *store;
    Method factory = class_getClassMethod(RNSCFileStore.class, @selector(defaultStore));
    IMP original = method_setImplementation(factory, imp_implementationWithBlock(^id(id cls) { return store; }));
    NSMutableArray *results = [NSMutableArray array];
    for (NSString *name in @[@"success_jpeg", @"success_png", @"jpeg_nil", @"png_nil", @"disk_full", @"permission_denied",
        @"cache_purged", @"codec_throws", @"write_throws", @"scale_throws", @"base64_throws", @"cancel_after_write",
        @"cancel_cleanup_throws", @"resolve_throws", @"reject_throws"]) {
        fault = [name isEqual:@"reject_throws"] ? @"codec_throws" : name;
        NSString *directory = [root stringByAppendingPathComponent:name];
        store = [[FaultStore alloc] initWithDirectory:directory manager:manager];
        EncodeProbe *probe = [EncodeProbe new];
        __block int resolves = 0, rejects = 0;
        __block NSError *failure;
        BOOL propagated = NO;
        @try {
            [probe encodeImage:[UIImage new] extension:[name containsString:@"png"] ? @"png" : @"jpeg" quality:50
                scale:[name isEqual:@"scale_throws"] ? 0.4 : 1 includeBase64:YES resolve:^(id result) {
                    resolves++; check([manager fileExistsAtPath:[NSURL URLWithString:result[@"uri"]].path]);
                    if ([name isEqual:@"resolve_throws"]) [NSException raise:@"Injected" format:@"resolve threw"];
                } reject:^(NSString *code, NSString *message, NSError *error) {
                    rejects++; failure = error;
                    if ([name isEqual:@"reject_throws"]) [NSException raise:@"Injected" format:@"reject threw"];
                }];
        } @catch (NSException *exception) { propagated = YES; }
        check(resolves + rejects == 1); check(probe.finishCalls == 1);
        BOOL succeeds = [name hasPrefix:@"success_"] || [name isEqual:@"cache_purged"] || [name isEqual:@"resolve_throws"];
        check(succeeds ? resolves == 1 : rejects == 1);
        check(propagated == ([name isEqual:@"resolve_throws"] || [name isEqual:@"reject_throws"]));
        if ([name isEqual:@"disk_full"]) check(failure.code == NSFileWriteOutOfSpaceError);
        if ([name isEqual:@"permission_denied"]) check(failure.code == NSFileWriteNoPermissionError);
        if ([name isEqual:@"cancel_cleanup_throws"]) check(failure.userInfo[NSUnderlyingErrorKey] != nil);
        check(RNSCAutoreleasedSentinelsAlive() == 0);
        if (!succeeds && ![name isEqual:@"cancel_cleanup_throws"]) check([manager contentsOfDirectoryAtPath:directory error:NULL].count == 0);
        [results addObject:@{@"case":name, @"resolve_calls":@(resolves), @"reject_calls":@(rejects), @"admission_releases":@(probe.finishCalls)}];
    }
    method_setImplementation(factory, original);
    fault = @"success_png";
    NSString *folder = [root stringByAppendingPathComponent:@"store"];
    FaultManager *faultManager = [FaultManager new];
    store = [[RNSCFileStore alloc] initWithDirectory:folder manager:faultManager];
    NSError *error = nil;
    NSString *path = [store writeData:[@"abc" dataUsingEncoding:NSUTF8StringEncoding] extension:@"png" error:&error];
    check(path != nil && error == nil);
    faultManager.failList = YES; check([store clear:&error] == 0 && error != nil);
    faultManager.failList = NO; chmod(folder.fileSystemRepresentation, 0500); error = nil;
    check([store clear:&error] == 0 && error != nil && [manager fileExistsAtPath:path]);
    chmod(folder.fileSystemRepresentation, 0700); error = nil; check([store clear:&error] == 1 && error == nil);
    check(![store releaseURI:[NSURL fileURLWithPath:path].absoluteString error:&error] && !error);
    NSString *outside = [root stringByAppendingPathComponent:@"outside"];
    [manager createDirectoryAtPath:outside withIntermediateDirectories:YES attributes:nil error:NULL];
    NSString *victim = [outside stringByAppendingPathComponent:@"CAPTURE-00000000-0000-0000-0000-000000000000.png"];
    [@"keep" writeToFile:victim atomically:YES encoding:NSUTF8StringEncoding error:NULL];
    [manager removeItemAtPath:folder error:NULL];
    [manager createSymbolicLinkAtPath:folder withDestinationPath:outside error:NULL];
    error = nil; check([store clear:&error] == 0 && error != nil);
    error = nil; check(![store releaseURI:[NSURL fileURLWithPath:[folder stringByAppendingPathComponent:victim.lastPathComponent]].absoluteString error:&error] && error != nil);
    check([manager fileExistsAtPath:victim]);
    [manager removeItemAtPath:folder error:NULL];
    [@"not a directory" writeToFile:folder atomically:YES encoding:NSUTF8StringEncoding error:NULL];
    error = nil; check([store writeData:[FaultData new] extension:@"png" error:&error] == nil && error != nil);
    [manager removeItemAtPath:folder error:NULL];
    // Construct the store before a parent alias exists, then publish/release/clear after
    // creating it. Foundation path normalization may change when the directory appears.
    NSString *realParent = [root stringByAppendingPathComponent:@"late-real-parent"];
    NSString *lateAlias = [root stringByAppendingPathComponent:@"late-parent-alias"];
    [manager createDirectoryAtPath:realParent withIntermediateDirectories:YES attributes:nil error:NULL];
    RNSCFileStore *lateStore = [[RNSCFileStore alloc]
        initWithDirectory:[lateAlias stringByAppendingPathComponent:@"cache"] manager:manager];
    [manager createSymbolicLinkAtPath:lateAlias withDestinationPath:realParent error:NULL];
    error = nil;
    NSString *latePath = [lateStore writeData:[@"alias fixture" dataUsingEncoding:NSUTF8StringEncoding]
                                  extension:@"png" error:&error];
    check(latePath != nil && error == nil);
    check([lateStore releaseURI:[NSURL fileURLWithPath:latePath].absoluteString error:&error] && error == nil);
    check(![lateStore releaseURI:[NSURL fileURLWithPath:latePath].absoluteString error:&error] && error == nil);
    latePath = [lateStore writeData:[@"alias cleanup" dataUsingEncoding:NSUTF8StringEncoding]
                         extension:@"png" error:&error];
    check(latePath != nil && error == nil);
    check([lateStore clear:&error] == 1 && error == nil);
    for (int i = 0; i < 100; i++) {
        error = nil; path = [store writeData:[FaultData new] extension:@"png" error:&error];
        check(path != nil && error == nil);
        check([store releaseURI:[NSURL fileURLWithPath:path].absoluteString error:&error] && error == nil);
    }
    check([manager contentsOfDirectoryAtPath:folder error:NULL].count == 0);
    UIWindow *tiny = [UIWindow new]; tiny.bounds = CGRectMake(0, 0, 1, 1);
    UIWindow *main = [UIWindow new]; main.bounds = CGRectMake(0, 0, 414, 896);
    UIWindow *large = [UIWindow new]; large.bounds = CGRectMake(0, 0, 800, 900);
    main.isKeyWindow = YES;
    check([RNSCWindowCapture primaryWindowForWindows:@[tiny, main, large]] == main);
    main.isKeyWindow = NO;
    check([RNSCWindowCapture primaryWindowForWindows:@[tiny, main, large]] == large);
    check([RNSCWindowCapture primaryWindowForWindows:@[main, tiny]] == main);
    check([RNSCWindowCapture primaryWindowForWindows:@[tiny]] == tiny);
    __block int completed = 0, followup = 0;
    WaitProvider *provider = [WaitProvider new];
    [RNSCWindowCapture performSerially:^(dispatch_block_t done) {
        [RNSCWindowCapture waitForFrames:@[provider] attempt:0 then:^(NSError *failure) { check(failure != nil); completed++; done(); }];
    }];
    [RNSCWindowCapture performSerially:^(dispatch_block_t done) { followup++; done(); done(); }];
    pumpUntil(^BOOL { return followup == 1; });
    check(completed == 1 && provider.calls == 9);
    pumpUntil(^BOOL { return !RNSCOperationRunning; });
    for (Class cls in @[PlayerBufferProbe.class, CameraBufferProbe.class, SampleBufferProbe.class]) {
        CVPixelBufferRef buffer = NULL;
        void *pixels = calloc(8 * 4, 4);
        check(CVPixelBufferCreateWithBytes(kCFAllocatorDefault, 8, 4, kCVPixelFormatType_32BGRA, pixels, 8 * 4,
            releasePixels, NULL, NULL, &buffer) == kCVReturnSuccess);
        BufferProbe *probe = [[cls alloc] initWithBuffer:buffer];
        CVPixelBufferRelease(buffer);
        int before = bufferFinalizations;
        BOOL threw = NO;
        @try { [probe newFrameImage]; } @catch (NSException *exception) { threw = YES; }
        [probe detach];
        check(threw && bufferFinalizations == before + 1);
    }
    NSData *json = [NSJSONSerialization dataWithJSONObject:@{@"checks":@(checks), @"passed":@YES, @"encode_cases":results,
        @"scope":@"Foundation filesystem and extracted production control flow; stub codecs/React, no UIKit/device proof"} options:NSJSONWritingPrettyPrinted error:NULL];
    fwrite(json.bytes, 1, json.length, stdout); fputc('\n', stdout);
    [manager removeItemAtPath:root error:NULL];
    return 0;
} }
