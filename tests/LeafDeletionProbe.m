#import <Foundation/Foundation.h>
#import "RNSCFileStore.h"

// Real small Foundation filesystem operations. No UIKit, RN bridge, device, or disk stress.
@interface SubstitutionManager : NSFileManager
@property(nonatomic, copy) NSString *target;
@property(nonatomic, copy) NSString *sentinel;
@property(nonatomic) BOOL armed;
@end

@implementation SubstitutionManager
- (NSDictionary *)attributesOfItemAtPath:(NSString *)path error:(NSError **)error
{
    NSDictionary *attributes = [super attributesOfItemAtPath:path error:error];
    if (self.armed && [path isEqual:self.target] &&
        [attributes[NSFileType] isEqual:NSFileTypeRegular]) {
        self.armed = NO;
        NSFileManager *real = NSFileManager.defaultManager;
        if (![real removeItemAtPath:path error:error] ||
            ![real createDirectoryAtPath:path withIntermediateDirectories:NO attributes:nil error:error] ||
            ![@"must survive" writeToFile:self.sentinel atomically:YES
                                 encoding:NSUTF8StringEncoding error:error])
            [NSException raise:@"ProbeSetup" format:@"Substitution failed: %@", *error];
    }
    // Return the original regular-file attributes, modeling replacement after validation.
    return attributes;
}
@end

int main(void)
{
    @autoreleasepool {
        NSFileManager *real = NSFileManager.defaultManager;
        NSString *root = [NSTemporaryDirectory() stringByAppendingPathComponent:
            [@"rnsc-leaf-substitution-" stringByAppendingString:NSUUID.UUID.UUIDString]];
        SubstitutionManager *manager = [SubstitutionManager new];
        RNSCFileStore *store = [[RNSCFileStore alloc] initWithDirectory:root manager:manager];
        NSError *error = nil;
        manager.target = [store writeData:[@"owned capture" dataUsingEncoding:NSUTF8StringEncoding]
                               extension:@"png" error:&error];
        if (!manager.target) return 2;
        manager.sentinel = [manager.target stringByAppendingPathComponent:@"sentinel"];
        manager.armed = YES;
        BOOL removed = [store releaseURI:[NSURL fileURLWithPath:manager.target].absoluteString error:&error];
        BOOL sentinelSurvived = [real fileExistsAtPath:manager.sentinel];
        BOOL passed = !removed && error != nil && sentinelSurvived && !manager.armed;
        printf("{\"passed\":%s,\"release_removed\":%s,\"sentinel_survived\":%s,\"error_code\":%ld}\n",
               passed ? "true" : "false", removed ? "true" : "false",
               sentinelSurvived ? "true" : "false", (long)error.code);
        // Only this probe's own temporary directory; production release never uses this cleanup.
        [real removeItemAtPath:root error:NULL];
        return passed ? 0 : 1;
    }
}
