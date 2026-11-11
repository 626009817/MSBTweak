#import <Foundation/Foundation.h>

void MSBInstallCameraHooks(void);
void MSBInstallCameraPreviewHooks(void);
void MSBInstallLocationHooks(void);
BOOL MSBSwizzle(Class cls, SEL original, SEL replacement);
