#import "MSBTweakHooks.h"
#import <objc/runtime.h>

BOOL MSBSwizzle(Class cls, SEL original, SEL replacement) {
    Method oldMethod = class_getInstanceMethod(cls, original);
    Method newMethod = class_getInstanceMethod(cls, replacement);
    if (!oldMethod || !newMethod) return NO;
    if (class_addMethod(cls, original, method_getImplementation(newMethod), method_getTypeEncoding(newMethod))) {
        class_replaceMethod(cls, replacement, method_getImplementation(oldMethod), method_getTypeEncoding(oldMethod));
    } else {
        method_exchangeImplementations(oldMethod, newMethod);
    }
    return YES;
}
