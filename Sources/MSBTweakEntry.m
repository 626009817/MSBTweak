#import "MSBTweakHooks.h"
#import "MSBTweakUI.h"

__attribute__((constructor)) static void MSBTweakInitialize(void) {
    @autoreleasepool {
        if ([NSBundle.mainBundle.bundlePath.pathExtension isEqualToString:@"appex"]) return;
        MSBInstallCameraHooks();
        MSBInstallLocationHooks();
        dispatch_async(dispatch_get_main_queue(), ^{ [[MSBOverlayCoordinator shared] start]; });
    }
}
