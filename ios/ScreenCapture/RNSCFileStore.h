#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/** The module's cache only. All operations run on RNSCFileQueue(). */
@interface RNSCFileStore : NSObject
- (instancetype)initWithDirectory:(NSString *)directory manager:(NSFileManager *)manager;
+ (instancetype)defaultStore;
- (nullable NSString *)writeData:(NSData *)data
                       extension:(NSString *)extension
                           error:(NSError **)error;
- (BOOL)releaseURI:(NSString *)uri error:(NSError **)error;
- (NSUInteger)clear:(NSError **)error;
@end

FOUNDATION_EXPORT dispatch_queue_t RNSCFileQueue(void);
NS_ASSUME_NONNULL_END
