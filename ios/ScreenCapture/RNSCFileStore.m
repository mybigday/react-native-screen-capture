#import "RNSCFileStore.h"
#include <errno.h>
#include <unistd.h>

// Unlike NSFileManager removal, unlink cannot recursively remove a replacement directory.
static int RNSCUnlinkLeafPath(const char *path)
{
    return unlink(path) == 0 ? 0 : errno;
}

dispatch_queue_t RNSCFileQueue(void)
{
    static dispatch_queue_t queue;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
      queue = dispatch_queue_create("com.fugood.screencapture.files", DISPATCH_QUEUE_SERIAL);
    });
    return queue;
}

@implementation RNSCFileStore
{
    NSString *_directory;
    NSFileManager *_manager;
}

- (instancetype)initWithDirectory:(NSString *)directory manager:(NSFileManager *)manager
{
    if ((self = [super init]))
    {
        _directory = [directory.stringByStandardizingPath copy];
        _manager = manager;
    }
    return self;
}

+ (instancetype)defaultStore
{
    NSString *caches =
        NSSearchPathForDirectoriesInDomains(NSCachesDirectory, NSUserDomainMask, YES).firstObject;
    return [[self alloc]
        initWithDirectory:[caches stringByAppendingPathComponent:@"react-native-screen-capture"]
                  manager:NSFileManager.defaultManager];
}

- (BOOL)ensureDirectory:(NSError **)error
{
    if (![_manager createDirectoryAtPath:_directory
             withIntermediateDirectories:YES
                              attributes:nil
                                   error:error])
        return NO;
    NSDictionary *attributes = [_manager attributesOfItemAtPath:_directory error:error];
    if (![attributes[NSFileType] isEqual:NSFileTypeDirectory])
    {
        if (error && !*error)
            *error = [NSError
                errorWithDomain:NSCocoaErrorDomain
                           code:NSFileWriteInvalidFileNameError
                       userInfo:@{NSLocalizedDescriptionKey : @"Capture cache is not a directory"}];
        return NO;
    }
    return YES;
}

- (BOOL)ownsName:(NSString *)name
{
    NSString *stem = name.stringByDeletingPathExtension;
    return [stem hasPrefix:@"CAPTURE-"] &&
           [[NSUUID alloc] initWithUUIDString:[stem substringFromIndex:8]] != nil &&
           ([@"png" isEqual:name.pathExtension] || [@"jpg" isEqual:name.pathExtension]);
}

- (nullable NSString *)writeData:(NSData *)data
                       extension:(NSString *)extension
                           error:(NSError **)error
{
    if (![self ensureDirectory:error])
        return nil;
    NSString *name =
        [NSString stringWithFormat:@"CAPTURE-%@.%@", NSUUID.UUID.UUIDString, extension];
    NSString *path = [_directory stringByAppendingPathComponent:name];
    if ([data writeToFile:path options:NSDataWritingAtomic error:error])
        return path;
    // The OS may purge a cache directory between creation and write. Retry that case once;
    // permissions and disk-full errors must reach the caller unchanged.
    if (error && [(*error).domain isEqual:NSCocoaErrorDomain] &&
        (*error).code == NSFileNoSuchFileError)
    {
        *error = nil;
        if ([self ensureDirectory:error] && [data writeToFile:path
                                                      options:NSDataWritingAtomic
                                                        error:error])
            return path;
    }
    // Best effort only; preserve the write error and never recurse into a replacement directory.
    (void)RNSCUnlinkLeafPath(path.fileSystemRepresentation);
    return nil;
}

- (BOOL)releaseURI:(NSString *)uri error:(NSError **)error
{
    NSURL *url = [NSURL URLWithString:uri];
    NSString *path = url.path.stringByStandardizingPath;
    NSString *parent = path.stringByDeletingLastPathComponent.stringByStandardizingPath;
    if (!url.isFileURL || (url.host.length && ![url.host isEqual:@"localhost"]) ||
        // Foundation can standardize an app-container alias differently after the cache
        // directory is created, or after a file is deleted. Normalize the parent separately
        // so releasing an already-missing file still compares two existing directories.
        ![parent isEqual:_directory.stringByStandardizingPath] ||
        ![self ownsName:path.lastPathComponent])
    {
        if (error)
            *error = [NSError
                errorWithDomain:NSCocoaErrorDomain
                           code:NSFileWriteInvalidFileNameError
                       userInfo:@{
                           NSLocalizedDescriptionKey : @"URI is not a capture owned by this module"
                       }];
        return NO;
    }
    NSDictionary *folder = [_manager attributesOfItemAtPath:_directory error:error];
    if (!folder && error && (*error).code == NSFileReadNoSuchFileError)
    {
        *error = nil;
        return NO;
    }
    if (![folder[NSFileType] isEqual:NSFileTypeDirectory])
    {
        if (error && !*error)
            *error = [NSError
                errorWithDomain:NSCocoaErrorDomain
                           code:NSFileWriteInvalidFileNameError
                       userInfo:@{
                           NSLocalizedDescriptionKey : @"Capture cache is not a regular directory"
                       }];
        return NO;
    }
    NSDictionary *attributes = [_manager attributesOfItemAtPath:path error:error];
    if (!attributes)
    {
        if (error && (*error).code == NSFileReadNoSuchFileError)
            *error = nil;
        return NO;
    }
    // Never follow links or recursively delete a directory supplied through a URI.
    if (![attributes[NSFileType] isEqual:NSFileTypeRegular] ||
        ![path.stringByResolvingSymlinksInPath
            isEqual:[_directory.stringByResolvingSymlinksInPath
                        stringByAppendingPathComponent:path.lastPathComponent]])
    {
        if (error)
            *error = [NSError errorWithDomain:NSCocoaErrorDomain
                                         code:NSFileWriteInvalidFileNameError
                                     userInfo:@{
                                         NSLocalizedDescriptionKey :
                                             @"Capture URI does not name a regular cache file"
                                     }];
        return NO;
    }
    int leafError = RNSCUnlinkLeafPath(path.fileSystemRepresentation);
    if (!leafError) return YES;
    // A purge or an external consumer can remove the file after its attributes were read.
    if (leafError == ENOENT) return NO;
    if (error)
    {
        NSError *underlying = [NSError errorWithDomain:NSPOSIXErrorDomain code:leafError
            userInfo:@{NSFilePathErrorKey: path}];
        NSInteger code = (leafError == EACCES || leafError == EPERM)
            ? NSFileWriteNoPermissionError
            : ((leafError == EISDIR || leafError == ENOTDIR)
                ? NSFileWriteInvalidFileNameError : NSFileWriteUnknownError);
        *error = [NSError errorWithDomain:NSCocoaErrorDomain code:code
            userInfo:@{NSLocalizedDescriptionKey: underlying.localizedDescription,
                       NSFilePathErrorKey: path, NSUnderlyingErrorKey: underlying}];
    }
    return NO;
}

- (NSUInteger)clear:(NSError **)error
{
    NSDictionary *folder = [_manager attributesOfItemAtPath:_directory error:error];
    if (!folder && error && (*error).code == NSFileReadNoSuchFileError)
    {
        *error = nil;
        return 0;
    }
    if (![folder[NSFileType] isEqual:NSFileTypeDirectory])
    {
        if (error && !*error)
            *error = [NSError
                errorWithDomain:NSCocoaErrorDomain
                           code:NSFileWriteInvalidFileNameError
                       userInfo:@{
                           NSLocalizedDescriptionKey : @"Capture cache is not a regular directory"
                       }];
        return 0;
    }
    NSArray<NSString *> *names = [_manager contentsOfDirectoryAtPath:_directory error:error];
    NSUInteger removed = 0;
    NSError *first = error ? *error : nil;
    for (NSString *name in names)
    {
        if (![self ownsName:name])
            continue;
        NSError *failure = nil;
        if ([self
                releaseURI:[NSURL fileURLWithPath:[_directory stringByAppendingPathComponent:name]]
                               .absoluteString
                     error:&failure])
            removed++;
        if (!first && failure)
            first = failure;
    }
    if (error)
        *error = first;
    return removed;
}
@end
