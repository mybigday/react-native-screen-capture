#import <Foundation/Foundation.h>
@interface RCTEventEmitter : NSObject
- (void)sendEventWithName:(NSString *)name body:(id)body;
- (void)invalidate;
@end
