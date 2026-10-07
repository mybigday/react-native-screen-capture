#import <Foundation/Foundation.h>

// Compile this tiny lifetime boundary without ARC so the queued autorelease is explicit.
static NSUInteger live;
@interface RNSCAutoreleaseSentinel : NSObject @end
@implementation RNSCAutoreleaseSentinel
- (instancetype)init { if ((self = [super init])) live++; return self; }
- (void)dealloc { live--; [super dealloc]; }
@end
void RNSCCreateAutoreleasedSentinel(void) { [[[RNSCAutoreleaseSentinel alloc] init] autorelease]; }
NSUInteger RNSCAutoreleasedSentinelsAlive(void) { return live; }
