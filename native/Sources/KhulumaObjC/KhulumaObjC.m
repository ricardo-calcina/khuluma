#import "KhulumaObjC.h"

NSErrorDomain const KHObjCExceptionDomain = @"KhulumaObjCException";
NSString *const KHObjCExceptionNameKey = @"KHObjCExceptionName";
NSString *const KHObjCExceptionReasonKey = @"KHObjCExceptionReason";

@implementation KHObjC

+ (BOOL)catchException:(NS_NOESCAPE void (^)(void))block error:(NSError **)error {
  @try {
    block();
    return YES;
  } @catch (NSException *exception) {
    if (error) {
      NSString *name = exception.name ?: @"NSException";
      NSString *reason = exception.reason ?: @"";
      *error = [NSError errorWithDomain:KHObjCExceptionDomain code:1 userInfo:@{
        KHObjCExceptionNameKey: name,
        KHObjCExceptionReasonKey: reason,
        NSLocalizedDescriptionKey: [NSString stringWithFormat:@"%@: %@", name, reason],
      }];
    }
    return NO;
  }
}

@end
