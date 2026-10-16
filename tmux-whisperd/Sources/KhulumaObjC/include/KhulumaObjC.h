#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// The NSError domain for an Objective-C exception caught by KHObjC.
extern NSErrorDomain const KHObjCExceptionDomain;
/// userInfo keys: the exception's name and reason.
extern NSString *const KHObjCExceptionNameKey;
extern NSString *const KHObjCExceptionReasonKey;

/// Swift cannot catch NSException. AVAudioEngine raises one for a failed
/// "required condition" (e.g. a tap format that no longer matches the input
/// device), and inside a Carbon event handler HIToolbox swallows it, silently
/// abandoning whatever Swift code was running.
@interface KHObjC : NSObject
/// Runs block; an NSException it raises comes back as an NSError in
/// KHObjCExceptionDomain (Swift: `try KHObjC.catchException { ... }`).
+ (BOOL)catchException:(NS_NOESCAPE void (^)(void))block error:(NSError *_Nullable *_Nullable)error;
@end

NS_ASSUME_NONNULL_END
