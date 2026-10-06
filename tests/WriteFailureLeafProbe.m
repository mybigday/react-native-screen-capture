#import <Foundation/Foundation.h>
#import "RNSCFileStore.h"

// Controlled write-error cleanup: all replacement files belong to this probe.
// No UIKit codec, React bridge, device, disk exhaustion, or memory exhaustion.
@interface ReplacementFailureData : NSData
@property(nonatomic, copy) NSString *sentinel;
@end
@implementation ReplacementFailureData
- (NSUInteger)length { return 3; }
- (const void *)bytes { return "abc"; }
- (BOOL)writeToFile:(NSString *)path options:(NSDataWritingOptions)options error:(NSError **)error
{
    NSFileManager *manager = NSFileManager.defaultManager;
    NSError *setup = nil;
    self.sentinel = [path stringByAppendingPathComponent:@"sentinel"];
    if (![manager createDirectoryAtPath:path withIntermediateDirectories:NO attributes:nil error:&setup] ||
        ![@"must survive" writeToFile:self.sentinel atomically:YES encoding:NSUTF8StringEncoding error:&setup])
        [NSException raise:@"ProbeSetup" format:@"Failed to create test-owned replacement: %@", setup];
    if (error) *error = [NSError errorWithDomain:NSCocoaErrorDomain code:NSFileWriteOutOfSpaceError
        userInfo:@{NSLocalizedDescriptionKey: @"Injected write failure"}];
    return NO;
}
@end

int main(void)
{
    @autoreleasepool {
        NSFileManager *manager = NSFileManager.defaultManager;
        NSString *root = [NSTemporaryDirectory() stringByAppendingPathComponent:
            [@"rnsc-write-failure-leaf-" stringByAppendingString:NSUUID.UUID.UUIDString]];
        RNSCFileStore *store = [[RNSCFileStore alloc] initWithDirectory:root manager:manager];
        ReplacementFailureData *data = [ReplacementFailureData new];
        NSError *error = nil;
        NSString *path = [store writeData:data extension:@"png" error:&error];
        BOOL survived = [manager fileExistsAtPath:data.sentinel];
        BOOL preserved = [error.domain isEqual:NSCocoaErrorDomain] && error.code == NSFileWriteOutOfSpaceError;
        BOOL passed = path == nil && survived && preserved;
        printf("{\"passed\":%s,\"sentinel_survived\":%s,\"primary_write_error_preserved\":%s}\n",
               passed ? "true" : "false", survived ? "true" : "false", preserved ? "true" : "false");
        // Only this probe's own tree; production cleanup must never recursively delete it.
        [manager removeItemAtPath:root error:NULL];
        return passed ? 0 : 1;
    }
}
