#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// The NSError domain for an Objective-C exception caught by LKObjC.
extern NSErrorDomain const LKObjCExceptionDomain;
/// userInfo keys: the exception's name and reason.
extern NSString *const LKObjCExceptionNameKey;
extern NSString *const LKObjCExceptionReasonKey;

/// Swift cannot catch NSException. AVAudioEngine raises one for a failed
/// "required condition" (e.g. a tap format that no longer matches the input
/// device), and inside a Carbon event handler HIToolbox swallows it, silently
/// abandoning whatever Swift code was running.
@interface LKObjC : NSObject
/// Runs block; an NSException it raises comes back as an NSError in
/// LKObjCExceptionDomain (Swift: `try LKObjC.catchException { ... }`).
+ (BOOL)catchException:(NS_NOESCAPE void (^)(void))block error:(NSError *_Nullable *_Nullable)error;
@end

NS_ASSUME_NONNULL_END
