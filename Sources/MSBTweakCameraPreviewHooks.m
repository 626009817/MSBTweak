#import "MSBTweakHooks.h"
#import "MSBTweakSettings.h"
#import <AVFoundation/AVFoundation.h>
#import <objc/runtime.h>

static char MSBPreviewOverlayKey;

static NSHashTable<AVCaptureVideoPreviewLayer *> *MSBPreviewLayers(void) {
    static NSHashTable *layers;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{ layers = [NSHashTable weakObjectsHashTable]; });
    return layers;
}

// All overlay mutations happen on the main queue. Keep the camera session and
// the host's layer geometry intact so focus gestures and camera controls work.
static void MSBUpdatePreview(AVCaptureVideoPreviewLayer *preview) {
    MSBSettings *settings = MSBSettings.shared;
    MSBPhotoAsset *asset = settings.cameraPreviewEnabled ? settings.selectedPhoto : nil;
    CALayer *overlay = objc_getAssociatedObject(preview, &MSBPreviewOverlayKey);
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    if (!asset || !preview.session) {
        [overlay removeFromSuperlayer];
        objc_setAssociatedObject(preview, &MSBPreviewOverlayKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    } else {
        if (!overlay) {
            overlay = [CALayer layer];
            overlay.name = @"MSBTweak.CameraReplacementPreview";
            overlay.backgroundColor = UIColor.blackColor.CGColor;
            overlay.masksToBounds = YES;
            objc_setAssociatedObject(preview, &MSBPreviewOverlayKey, overlay, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
        if (overlay.superlayer != preview) [preview addSublayer:overlay];
        if (!CGRectEqualToRect(overlay.frame, preview.bounds)) overlay.frame = preview.bounds;
        if (overlay.contents != (__bridge id)asset.image.CGImage) overlay.contents = (__bridge id)asset.image.CGImage;
        CALayerContentsGravity gravity = kCAGravityResizeAspect;
        if ([preview.videoGravity isEqualToString:AVLayerVideoGravityResizeAspectFill]) gravity = kCAGravityResizeAspectFill;
        else if ([preview.videoGravity isEqualToString:AVLayerVideoGravityResize]) gravity = kCAGravityResize;
        if (![overlay.contentsGravity isEqualToString:gravity]) overlay.contentsGravity = gravity;
    }
    [CATransaction commit];
}

static void MSBRefreshPreview(AVCaptureVideoPreviewLayer *preview) {
    NSHashTable *layers = MSBPreviewLayers();
    @synchronized (layers) { [layers addObject:preview]; }
    if (NSThread.isMainThread) MSBUpdatePreview(preview);
    else dispatch_async(dispatch_get_main_queue(), ^{ MSBUpdatePreview(preview); });
}

@interface AVCaptureVideoPreviewLayer (MSBTweak)
- (void)msb_layoutSublayers;
- (void)msb_setSession:(AVCaptureSession *)session;
- (void)msb_setSessionWithNoConnection:(AVCaptureSession *)session;
- (void)msb_setVideoGravity:(AVLayerVideoGravity)gravity;
@end

@implementation AVCaptureVideoPreviewLayer (MSBTweak)
- (void)msb_layoutSublayers {
    [self msb_layoutSublayers];
    MSBRefreshPreview(self);
}
- (void)msb_setSession:(AVCaptureSession *)session {
    [self msb_setSession:session];
    MSBRefreshPreview(self);
}
- (void)msb_setSessionWithNoConnection:(AVCaptureSession *)session {
    [self msb_setSessionWithNoConnection:session];
    MSBRefreshPreview(self);
}
- (void)msb_setVideoGravity:(AVLayerVideoGravity)gravity {
    [self msb_setVideoGravity:gravity];
    MSBRefreshPreview(self);
}
@end

void MSBInstallCameraPreviewHooks(void) {
    MSBSwizzle(AVCaptureVideoPreviewLayer.class, @selector(layoutSublayers), @selector(msb_layoutSublayers));
    MSBSwizzle(AVCaptureVideoPreviewLayer.class, @selector(setSession:), @selector(msb_setSession:));
    MSBSwizzle(AVCaptureVideoPreviewLayer.class, @selector(setSessionWithNoConnection:), @selector(msb_setSessionWithNoConnection:));
    MSBSwizzle(AVCaptureVideoPreviewLayer.class, @selector(setVideoGravity:), @selector(msb_setVideoGravity:));
    [[NSNotificationCenter defaultCenter] addObserverForName:MSBSettingsDidChangeNotification object:nil
        queue:NSOperationQueue.mainQueue usingBlock:^(__unused NSNotification *notification) {
            NSHashTable *layers = MSBPreviewLayers();
            NSArray *previews;
            @synchronized (layers) { previews = layers.allObjects; }
            for (AVCaptureVideoPreviewLayer *preview in previews) MSBUpdatePreview(preview);
        }];
}
