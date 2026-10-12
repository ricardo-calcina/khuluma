#import "LowkeyObjC.h"

NSErrorDomain const LKObjCExceptionDomain = @"LowkeyObjCException";
NSString *const LKObjCExceptionNameKey = @"LKObjCExceptionName";
NSString *const LKObjCExceptionReasonKey = @"LKObjCExceptionReason";

@implementation LKObjC

+ (BOOL)catchException:(NS_NOESCAPE void (^)(void))block error:(NSError **)error {
  @try {
    block();
    return YES;
  } @catch (NSException *exception) {
    if (error) {
      NSString *name = exception.name ?: @"NSException";
      NSString *reason = exception.reason ?: @"";
      *error = [NSError errorWithDomain:LKObjCExceptionDomain code:1 userInfo:@{
        LKObjCExceptionNameKey: name,
        LKObjCExceptionReasonKey: reason,
        NSLocalizedDescriptionKey: [NSString stringWithFormat:@"%@: %@", name, reason],
      }];
    }
    return NO;
  }
}

@end
