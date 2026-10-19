#import <Foundation/Foundation.h>
// Syntax-check boundary only; no React implementation or bridge behavior is simulated here.
typedef void (^RCTPromiseResolveBlock)(id);
typedef void (^RCTPromiseRejectBlock)(NSString *, NSString *, NSError *);
@protocol RCTBridgeModule <NSObject>
@end
#define RCT_EXPORT_MODULE(...)
#define RCT_EXPORT_METHOD(method) - (void)method
