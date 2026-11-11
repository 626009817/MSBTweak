#import <UIKit/UIKit.h>
#import <AVFoundation/AVFoundation.h>
#import <CoreLocation/CoreLocation.h>
#import <objc/runtime.h>
#import <ImageIO/ImageIO.h>
#import "MSBTweakSettings.h"
#import "MSBTweakUI.h"

// These test objects exercise callback adaptation without requiring a physical camera.
@interface MSBTestPhoto : NSObject
@property(nonatomic, strong) NSData *originalData;
@property(nonatomic, strong) id originalBufferOwner;
@property(nonatomic, strong) id originalPreviewOwner;
- (NSData *)fileDataRepresentation;
- (CGImageRef)CGImageRepresentation;
- (CVPixelBufferRef)pixelBuffer;
- (CVPixelBufferRef)previewPixelBuffer;
- (NSDictionary *)metadata;
@end
@implementation MSBTestPhoto
- (NSDictionary *)metadata { return @{}; }
- (BOOL)isRawPhoto { return NO; }
- (NSData *)fileDataRepresentation { return nil; }
- (CGImageRef)CGImageRepresentation { return NULL; }
- (CVPixelBufferRef)pixelBuffer { return NULL; }
- (CVPixelBufferRef)previewPixelBuffer { return NULL; }
- (NSData *)msb_fileDataRepresentation { return self.originalData; }
- (NSData *)msb_fileDataRepresentationWithCustomizer:(id)customizer { (void)customizer; return self.originalData; }
- (CVPixelBufferRef)msb_pixelBuffer { return (__bridge CVPixelBufferRef)self.originalBufferOwner; }
- (CVPixelBufferRef)msb_previewPixelBuffer { return (__bridge CVPixelBufferRef)self.originalPreviewOwner; }
- (CGImageRef)msb_previewCGImageRepresentation { return NULL; }
@end

@interface MSBTestPhotoDelegate : NSObject <AVCapturePhotoCaptureDelegate>
@property(nonatomic, strong) NSData *data;
@end
@implementation MSBTestPhotoDelegate
- (void)captureOutput:(AVCapturePhotoOutput *)output didFinishProcessingPhoto:(AVCapturePhoto *)photo error:(NSError *)error {
    (void)output; (void)error;
    self.data = photo.fileDataRepresentation;
}
@end

@interface MSBTestLegacyDelegate : NSObject <AVCapturePhotoCaptureDelegate>
@property(nonatomic) BOOL receivedMainImage;
@property(nonatomic) BOOL receivedPreviewImage;
@property(nonatomic) OSType mainFormat;
@property(nonatomic) OSType previewFormat;
@property(nonatomic) size_t previewWidth;
@property(nonatomic, strong) NSData *JPEGData;
@property(nonatomic, strong) NSDictionary *metadata;
@end
@implementation MSBTestLegacyDelegate
- (void)captureOutput:(AVCapturePhotoOutput *)output didFinishProcessingPhotoSampleBuffer:(CMSampleBufferRef)sample
    previewPhotoSampleBuffer:(CMSampleBufferRef)preview resolvedSettings:(AVCaptureResolvedPhotoSettings *)settings
    bracketSettings:(AVCaptureBracketedStillImageSettings *)bracket error:(NSError *)error {
    (void)output; (void)settings; (void)bracket; (void)error;
    CVPixelBufferRef main = sample ? CMSampleBufferGetImageBuffer(sample) : NULL;
    CVPixelBufferRef thumbnail = preview ? CMSampleBufferGetImageBuffer(preview) : NULL;
    self.receivedMainImage = main != NULL;
    self.receivedPreviewImage = thumbnail != NULL;
    self.mainFormat = main ? CVPixelBufferGetPixelFormatType(main) : 0;
    self.previewFormat = thumbnail ? CVPixelBufferGetPixelFormatType(thumbnail) : 0;
    self.previewWidth = thumbnail ? CVPixelBufferGetWidth(thumbnail) : 0;
    self.metadata = sample ? CFBridgingRelease(CMCopyDictionaryOfAttachments(kCFAllocatorDefault, sample,
        kCMAttachmentMode_ShouldPropagate)) : nil;
    CMFormatDescriptionRef format = sample ? CMSampleBufferGetFormatDescription(sample) : NULL;
    self.JPEGData = format && CMFormatDescriptionGetMediaSubType(format) == kCMVideoCodecType_JPEG ?
        [AVCaptureStillImageOutput jpegStillImageNSDataRepresentation:sample] : nil;
}
@end

static CMSampleBufferRef MSBTestSample(CVPixelBufferRef buffer) CF_RETURNS_RETAINED;
static CMSampleBufferRef MSBTestSample(CVPixelBufferRef buffer) {
    CMVideoFormatDescriptionRef format = NULL;
    CMSampleBufferRef sample = NULL;
    if (!buffer || CMVideoFormatDescriptionCreateForImageBuffer(kCFAllocatorDefault, buffer, &format) != noErr) return NULL;
    CMSampleTimingInfo timing = {CMTimeMake(1, 30), CMTimeMake(1, 1), kCMTimeInvalid};
    CMSampleBufferCreateReadyWithImageBuffer(kCFAllocatorDefault, buffer, format, &timing, &sample);
    CFRelease(format);
    return sample;
}

static NSDictionary *MSBTestImageProperties(NSData *data) {
    CGImageSourceRef source = data ? CGImageSourceCreateWithData((__bridge CFDataRef)data, NULL) : NULL;
    NSDictionary *properties = source ? CFBridgingRelease(CGImageSourceCopyPropertiesAtIndex(source, 0, NULL)) : nil;
    if (source) CFRelease(source);
    return properties ?: @{};
}

static NSData *MSBTestJPEGWithMetadata(UIImage *image, NSInteger orientation) {
    NSMutableData *data = [NSMutableData data];
    CGImageDestinationRef destination = CGImageDestinationCreateWithData((__bridge CFMutableDataRef)data,
        CFSTR("public.jpeg"), 1, NULL);
    if (!destination) return nil;
    NSDictionary *metadata = @{
        (id)kCGImagePropertyOrientation: @(orientation),
        (id)kCGImagePropertyExifDictionary: @{
            (id)kCGImagePropertyExifDateTimeOriginal: @"2024:03:12 10:11:12",
            (id)kCGImagePropertyExifExposureTime: @(0.008),
            (id)kCGImagePropertyExifFNumber: @2.8,
            (id)kCGImagePropertyExifPixelXDimension: @(CGImageGetWidth(image.CGImage)),
            (id)kCGImagePropertyExifPixelYDimension: @(CGImageGetHeight(image.CGImage))
        },
        (id)kCGImagePropertyTIFFDictionary: @{
            (id)kCGImagePropertyTIFFMake: @"EXIF Test Camera",
            (id)kCGImagePropertyTIFFModel: @"Fixture",
            (id)kCGImagePropertyTIFFOrientation: @(orientation)
        },
        (id)kCGImagePropertyGPSDictionary: @{
            (id)kCGImagePropertyGPSLatitude: @31.2304, (id)kCGImagePropertyGPSLatitudeRef: @"N",
            (id)kCGImagePropertyGPSLongitude: @121.4737, (id)kCGImagePropertyGPSLongitudeRef: @"E"
        }
    };
    CGImageDestinationAddImage(destination, image.CGImage, (__bridge CFDictionaryRef)metadata);
    BOOL success = CGImageDestinationFinalize(destination);
    CFRelease(destination);
    return success ? [data copy] : nil;
}

static BOOL MSBTestHasPhotoMetadata(NSDictionary *properties) {
    NSDictionary *exif = properties[(id)kCGImagePropertyExifDictionary];
    NSDictionary *tiff = properties[(id)kCGImagePropertyTIFFDictionary];
    NSDictionary *gps = properties[(id)kCGImagePropertyGPSDictionary];
    return [exif[(id)kCGImagePropertyExifDateTimeOriginal] isEqual:@"2024:03:12 10:11:12"] &&
        fabs([exif[(id)kCGImagePropertyExifExposureTime] doubleValue] - 0.008) < 0.00001 &&
        fabs([exif[(id)kCGImagePropertyExifFNumber] doubleValue] - 2.8) < 0.001 &&
        [tiff[(id)kCGImagePropertyTIFFMake] isEqual:@"EXIF Test Camera"] &&
        [tiff[(id)kCGImagePropertyTIFFModel] isEqual:@"Fixture"] &&
        fabs([gps[(id)kCGImagePropertyGPSLatitude] doubleValue] - 31.2304) < 0.00001 &&
        fabs([gps[(id)kCGImagePropertyGPSLongitude] doubleValue] - 121.4737) < 0.00001;
}

@interface MSBTestPan : UIPanGestureRecognizer
@property(nonatomic) UIGestureRecognizerState testState;
@property(nonatomic) CGPoint testTranslation;
@end
@implementation MSBTestPan
- (UIGestureRecognizerState)state { return self.testState; }
- (CGPoint)translationInView:(UIView *)view { (void)view; return self.testTranslation; }
@end

@interface MSBTestRequestManager : CLLocationManager
@property(nonatomic) NSUInteger originalRequests;
@end
@implementation MSBTestRequestManager
- (CLAuthorizationStatus)authorizationStatus { return kCLAuthorizationStatusAuthorizedWhenInUse; }
- (void)msb_requestLocation { self.originalRequests++; }
@end

@interface MSBTestAppDelegate : UIResponder <UIApplicationDelegate, CLLocationManagerDelegate>
@property(nonatomic, strong) UIWindow *window;
@property(nonatomic, strong) UIButton *hostButton;
@property(nonatomic, strong) UILabel *status;
@property(nonatomic, strong) NSMutableArray *results;
@property(nonatomic, strong) CLLocationManager *manager;
@property(nonatomic, strong) CLLocation *lastLocation;
@property(nonatomic) NSUInteger locationCount;
@property(nonatomic) NSUInteger hostTapCount;
@end

@implementation MSBTestAppDelegate
- (void)check:(BOOL)passed name:(NSString *)name {
    [self.results addObject:@{@"name": name, @"passed": @(passed)}];
    NSLog(@"MSBTEST %@ %@", passed ? @"PASS" : @"FAIL", name);
}
- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)options {
    (void)application; (void)options;
    self.results = [NSMutableArray array];
    self.window = [[UIWindow alloc] initWithFrame:UIScreen.mainScreen.bounds];
    UIViewController *root = [UIViewController new];
    root.view.backgroundColor = UIColor.systemBackgroundColor;
    self.hostButton = [UIButton buttonWithType:UIButtonTypeSystem];
    self.hostButton.frame = CGRectMake(40, 170, 300, 64);
    [self.hostButton setTitle:@"宿主按钮：点击验证交互" forState:UIControlStateNormal];
    [self.hostButton addTarget:self action:@selector(hostTapped) forControlEvents:UIControlEventTouchUpInside];
    [root.view addSubview:self.hostButton];
    self.status = [[UILabel alloc] initWithFrame:CGRectMake(24, 260, 350, 220)];
    self.status.numberOfLines = 0;
    self.status.text = @"MSBTweak 测试宿主\n正在检查悬浮层与 Hook…";
    [root.view addSubview:self.status];
    self.window.rootViewController = root;
    [self.window makeKeyAndVisible];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC), dispatch_get_main_queue(), ^{ [self runChecks]; });
    return YES;
}
- (void)hostTapped { self.hostTapCount++; }
- (UIWindow *)overlayWindow {
    for (UIWindow *window in UIApplication.sharedApplication.windows) {
        if ([window isKindOfClass:NSClassFromString(@"MSBOverlayWindow")]) return window;
    }
    return nil;
}
- (UIButton *)floatingButton {
    for (UIView *view in self.overlayWindow.rootViewController.view.subviews) if ([view isKindOfClass:UIButton.class]) return (UIButton *)view;
    return nil;
}
- (NSData *)imageData:(UIColor *)color {
    UIGraphicsImageRenderer *renderer = [[UIGraphicsImageRenderer alloc] initWithSize:CGSizeMake(180, 120)];
    return [renderer PNGDataWithActions:^(UIGraphicsImageRendererContext *context) {
        [color setFill];
        [context fillRect:CGRectMake(0, 0, 180, 120)];
        [UIColor.whiteColor setFill];
        [context fillRect:CGRectMake(20, 20, 60, 40)];
    }];
}
- (void)runChecks {
    MSBSettings *settings = MSBSettings.shared;
    settings.cameraEnabled = NO;
    settings.cameraPreviewEnabled = NO;
    settings.locationEnabled = NO;
    [self check:!self.overlayWindow.isKeyWindow && self.window.isKeyWindow name:@"悬浮入口不抢占宿主 keyWindow"];
    UIButton *floating = self.floatingButton;
    [self check:floating && CGSizeEqualToSize(floating.bounds.size, CGSizeMake(44, 44)) name:@"悬浮入口为 44×44 pt"];
    CGPoint hostPoint = [self.hostButton convertPoint:CGPointMake(20, 20) toView:self.overlayWindow];
    [self check:[self.overlayWindow hitTest:hostPoint withEvent:nil] == nil name:@"悬浮窗口在宿主按钮位置穿透触摸"];
    [self check:[self.overlayWindow hitTest:floating.center withEvent:nil] == floating name:@"悬浮图标可以接收触摸"];
    [self.hostButton sendActionsForControlEvents:UIControlEventTouchUpInside];
    [self check:self.hostTapCount == 1 name:@"宿主按钮可以正常交互"];
    MSBTestPan *pan = [MSBTestPan new];
    pan.testState = UIGestureRecognizerStateBegan;
    [UIApplication.sharedApplication sendAction:NSSelectorFromString(@"drag:") to:self.overlayWindow.rootViewController from:pan forEvent:nil];
    pan.testTranslation = CGPointMake(-10000, 10000);
    pan.testState = UIGestureRecognizerStateChanged;
    [UIApplication.sharedApplication sendAction:NSSelectorFromString(@"drag:") to:self.overlayWindow.rootViewController from:pan forEvent:nil];
    pan.testState = UIGestureRecognizerStateEnded;
    [UIApplication.sharedApplication sendAction:NSSelectorFromString(@"drag:") to:self.overlayWindow.rootViewController from:pan forEvent:nil];
    CGRect safeBounds = UIEdgeInsetsInsetRect(self.overlayWindow.rootViewController.view.bounds,
                                             self.overlayWindow.rootViewController.view.safeAreaInsets);
    [self check:CGRectContainsRect(safeBounds, floating.frame) name:@"拖动超出屏幕时图标仍限制在安全区域"];
    NSDictionary *position = [NSUserDefaults.standardUserDefaults dictionaryForKey:@"MSBTweak.FloatingPosition.v1"];
    [self check:position && ![position[@"right"] boolValue] && [position[@"y"] doubleValue] <= 1 name:@"拖动后吸附左边缘并保存位置"];
    [self check:![settings importPhotoData:[@"invalid" dataUsingEncoding:NSUTF8StringEncoding] error:nil] name:@"拒绝无效图片"];
    UIGraphicsImageRendererFormat *format = [UIGraphicsImageRendererFormat defaultFormat];
    format.scale = 1;
    UIGraphicsImageRenderer *wideRenderer = [[UIGraphicsImageRenderer alloc] initWithSize:CGSizeMake(5000, 100) format:format];
    UIImage *wideImage = [wideRenderer imageWithActions:^(UIGraphicsImageRendererContext *context) {
        [UIColor.systemBlueColor setFill];
        [context fillRect:CGRectMake(0, 0, 5000, 100)];
    }];
    [self check:[settings importPhotoData:MSBTestJPEGWithMetadata(wideImage, 6) error:nil]
               name:@"导入带旋转方向和 EXIF 的大尺寸照片"];
    NSDictionary *normalized = MSBTestImageProperties(settings.selectedPhoto.JPEGData);
    NSDictionary *normalizedExif = normalized[(id)kCGImagePropertyExifDictionary];
    [self check:MSBTestHasPhotoMetadata(normalized) &&
               [normalized[(id)kCGImagePropertyOrientation] integerValue] == 1 &&
               [normalized[(id)kCGImagePropertyTIFFDictionary][(id)kCGImagePropertyTIFFOrientation] integerValue] == 1 &&
               [normalized[(id)kCGImagePropertyPixelHeight] integerValue] == 4096 &&
               [normalized[(id)kCGImagePropertyPixelWidth] integerValue] < 100 &&
               [normalizedExif[(id)kCGImagePropertyExifPixelXDimension] isEqual:normalized[(id)kCGImagePropertyPixelWidth]] &&
               [normalizedExif[(id)kCGImagePropertyExifPixelYDimension] isEqual:normalized[(id)kCGImagePropertyPixelHeight]]
               name:@"旋转缩放后保留 EXIF、GPS 和相机信息并更新方向及像素尺寸"];
    NSData *metadataJPEG = MSBTestJPEGWithMetadata([UIImage imageWithData:[self imageData:UIColor.systemBlueColor]], 1);
    [self check:[settings importPhotoData:metadataJPEG error:nil] name:@"导入并规范化图片"];
    MSBPhotoAsset *snapshot = settings.selectedPhoto;
    [self check:MSBTestHasPhotoMetadata(MSBTestImageProperties(snapshot.JPEGData)) && MSBTestHasPhotoMetadata(snapshot.metadata)
               name:@"导入后的 JPEG 文件与内存元数据都保留原图 EXIF"];
    MSBSettings *metadataReloaded = [MSBSettings new];
    [self check:MSBTestHasPhotoMetadata(metadataReloaded.selectedPhoto.metadata) name:@"重新加载设置保留照片 EXIF"];
    [self check:[settings saveConfigurationNamed:@"测试·EXIF" error:nil] name:@"保存含 EXIF 的照片配置"];
    [self check:settings.replacementPhoto == nil name:@"开关关闭时不替换照片"];
    settings.cameraEnabled = YES;
    [self check:settings.replacementPhoto == snapshot name:@"开关开启后返回已选图片"];
    [settings importPhotoData:[self imageData:UIColor.systemOrangeColor] error:nil];
    [self check:snapshot != settings.selectedPhoto name:@"导入新照片保留在途拍照的旧快照"];
    [self check:settings.selectedPhoto.metadata[(id)kCGImagePropertyGPSDictionary] == nil &&
               settings.selectedPhoto.metadata[(id)kCGImagePropertyExifDictionary][(id)kCGImagePropertyExifDateTimeOriginal] == nil
               name:@"无 EXIF 的新照片不会沿用上一张照片的拍摄信息"];
    [self check:[settings applyConfigurationNamed:@"测试·EXIF" error:nil] &&
               MSBTestHasPhotoMetadata(settings.selectedPhoto.metadata) name:@"切换配置恢复照片 EXIF"];
    [settings deleteConfigurationNamed:@"测试·EXIF" error:nil];
    [settings importPhotoData:[self imageData:UIColor.systemOrangeColor] error:nil];

    for (NSString *name in @[@"fileDataRepresentation", @"CGImageRepresentation", @"pixelBuffer", @"previewPixelBuffer", @"metadata"]) {
        SEL selector = NSSelectorFromString(name);
        Method method = class_getInstanceMethod(AVCapturePhoto.class, selector);
        class_replaceMethod(MSBTestPhoto.class, selector, method_getImplementation(method), method_getTypeEncoding(method));
    }
    MSBTestPhoto *photo = [MSBTestPhoto new];
    photo.originalData = snapshot.JPEGData;
    CVPixelBufferRef originalBuffer = NULL;
    CVPixelBufferCreate(kCFAllocatorDefault, 48, 32, kCVPixelFormatType_32BGRA,
                       (__bridge CFDictionaryRef)@{(id)kCVPixelBufferIOSurfacePropertiesKey: @{}}, &originalBuffer);
    photo.originalBufferOwner = CFBridgingRelease(originalBuffer);
    MSBTestPhotoDelegate *target = [MSBTestPhotoDelegate new];
    id proxy = [NSClassFromString(@"MSBPhotoDelegate") new];
    [proxy setValue:target forKey:@"target"];
    [proxy setValue:snapshot forKey:@"asset"];
    [(id<AVCapturePhotoCaptureDelegate>)proxy captureOutput:nil didFinishProcessingPhoto:(id)photo error:nil];
    [self check:[target.data isEqualToData:snapshot.JPEGData] name:@"拍照代理返回拍摄开始时的 JPEG 快照"];
    [self check:photo.CGImageRepresentation == snapshot.image.CGImage name:@"CGImage 接口返回替换图像"];
    CVPixelBufferRef buffer = photo.pixelBuffer;
    [self check:buffer && buffer != originalBuffer && CVPixelBufferGetWidth(buffer) == 48 && CVPixelBufferGetHeight(buffer) == 32
               name:@"PixelBuffer 返回替换内容且保留原尺寸"];
    if (buffer) {
        CVPixelBufferLockBaseAddress(buffer, kCVPixelBufferLock_ReadOnly);
        uint8_t *bytes = CVPixelBufferGetBaseAddress(buffer);
        size_t stride = CVPixelBufferGetBytesPerRow(buffer);
        uint8_t *top = bytes + 8 * stride + 10 * 4;
        uint8_t *bottom = bytes + 25 * stride + 10 * 4;
        [self check:top[0] > 220 && top[1] > 220 && top[2] > 220 && bottom[2] < 100
                   name:@"替换缓冲区像素内容正确且上下方向一致"];
        CVPixelBufferUnlockBaseAddress(buffer, kCVPixelBufferLock_ReadOnly);
    }
    [self check:MSBTestHasPhotoMetadata(MSBTestImageProperties(target.data)) && MSBTestHasPhotoMetadata(photo.metadata)
               name:@"拍照回调的 JPEG 与 metadata 接口均保留 EXIF"];
    NSDictionary *bufferExif = buffer ? (__bridge NSDictionary *)CVBufferGetAttachment(buffer, kCGImagePropertyExifDictionary, NULL) : nil;
    [self check:[bufferExif[(id)kCGImagePropertyExifDateTimeOriginal] isEqual:@"2024:03:12 10:11:12"] &&
               [bufferExif[(id)kCGImagePropertyExifPixelXDimension] integerValue] == 48 &&
               [bufferExif[(id)kCGImagePropertyExifPixelYDimension] integerValue] == 32
               name:@"像素缓冲区保留 EXIF 并使用缓冲区的实际尺寸"];
    [self check:photo.previewPixelBuffer == NULL name:@"未请求预览时 previewPixelBuffer 保持 nil"];
    MSBTestPhoto *compressed = [MSBTestPhoto new];
    compressed.originalData = snapshot.JPEGData;
    [(id<AVCapturePhotoCaptureDelegate>)proxy captureOutput:nil didFinishProcessingPhoto:(id)compressed error:nil];
    [self check:compressed.pixelBuffer == NULL name:@"压缩照片的 pixelBuffer 保持 nil"];
    MSBTestPhoto *yuv = [MSBTestPhoto new];
    yuv.originalData = snapshot.JPEGData;
    CVPixelBufferRef yuvOriginal = NULL, previewOriginal = NULL;
    CVPixelBufferCreate(kCFAllocatorDefault, 48, 32, kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
                       (__bridge CFDictionaryRef)@{(id)kCVPixelBufferIOSurfacePropertiesKey: @{}}, &yuvOriginal);
    CVPixelBufferCreate(kCFAllocatorDefault, 24, 16, kCVPixelFormatType_32BGRA,
                       (__bridge CFDictionaryRef)@{(id)kCVPixelBufferIOSurfacePropertiesKey: @{}}, &previewOriginal);
    yuv.originalBufferOwner = CFBridgingRelease(yuvOriginal);
    yuv.originalPreviewOwner = CFBridgingRelease(previewOriginal);
    [(id<AVCapturePhotoCaptureDelegate>)proxy captureOutput:nil didFinishProcessingPhoto:(id)yuv error:nil];
    CVPixelBufferRef yuvResult = yuv.pixelBuffer;
    [self check:yuvResult && yuvResult != yuvOriginal && CVPixelBufferGetPixelFormatType(yuvResult) == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange &&
               CVPixelBufferGetPlaneCount(yuvResult) == 2 name:@"YUV 照片保留 420f 双平面格式并替换内容"];
    [self check:yuv.previewPixelBuffer && yuv.previewPixelBuffer != previewOriginal && CVPixelBufferGetWidth(yuv.previewPixelBuffer) == 24 &&
               CVPixelBufferGetPixelFormatType(yuv.previewPixelBuffer) == kCVPixelFormatType_32BGRA name:@"预览缓冲区保留独立尺寸和格式"];
    for (NSString *type in @[@"public.png", @"public.heic"]) {
        NSMutableData *encoded = [NSMutableData data];
        CGImageDestinationRef destination = CGImageDestinationCreateWithData((__bridge CFMutableDataRef)encoded,
            (__bridge CFStringRef)type, 1, NULL);
        BOOL encodedOK = NO;
        if (destination) {
            CGImageDestinationAddImage(destination, settings.selectedPhoto.image.CGImage, NULL);
            encodedOK = CGImageDestinationFinalize(destination);
            CFRelease(destination);
        }
        MSBTestPhoto *containerPhoto = [MSBTestPhoto new];
        containerPhoto.originalData = encoded;
        [(id<AVCapturePhotoCaptureDelegate>)proxy captureOutput:nil didFinishProcessingPhoto:(id)containerPhoto error:nil];
        NSData *replacementData = containerPhoto.fileDataRepresentation;
        CGImageSourceRef source = CGImageSourceCreateWithData((__bridge CFDataRef)replacementData, NULL);
        NSString *actualType = source ? (__bridge NSString *)CGImageSourceGetType(source) : nil;
        [self check:encodedOK && [actualType isEqualToString:type] && ![replacementData isEqualToData:encoded]
                   name:[NSString stringWithFormat:@"照片替换保留 %@ 文件容器", type]];
        [self check:MSBTestHasPhotoMetadata(MSBTestImageProperties(replacementData))
                   name:[NSString stringWithFormat:@"%@ 输出保留 EXIF、GPS 和相机信息", type]];
        if (source) CFRelease(source);
    }
    [self check:[photo.metadata[@"Orientation"] integerValue] == 1 name:@"替换照片的方向元数据一致"];
    MSBTestLegacyDelegate *legacy = [MSBTestLegacyDelegate new];
    [proxy setValue:legacy forKey:@"target"];
    [self check:![proxy respondsToSelector:@selector(captureOutput:didFinishProcessingPhoto:error:)] name:@"旧版代理不虚报现代回调支持"];
    CMSampleBufferRef mainSample = MSBTestSample(yuvOriginal);
    CMSampleBufferRef previewSample = MSBTestSample(previewOriginal);
    [(id<AVCapturePhotoCaptureDelegate>)proxy captureOutput:nil didFinishProcessingPhotoSampleBuffer:mainSample
        previewPhotoSampleBuffer:previewSample resolvedSettings:nil bracketSettings:nil error:nil];
    [self check:legacy.receivedMainImage && legacy.mainFormat == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
               name:@"旧版照片 sample buffer 保留未压缩 YUV 格式"];
    [self check:legacy.receivedPreviewImage && legacy.previewFormat == kCVPixelFormatType_32BGRA && legacy.previewWidth == 24
               name:@"旧版预览 sample buffer 包含独立未压缩图像"];
    [self check:MSBTestHasPhotoMetadata(legacy.metadata) &&
               [legacy.metadata[(id)kCGImagePropertyExifDictionary][(id)kCGImagePropertyExifPixelXDimension] integerValue] == 48
               name:@"旧版未压缩照片附件保留 EXIF 并更新尺寸"];
    CMBlockBufferRef jpegBlock = NULL;
    CMVideoFormatDescriptionRef jpegFormat = NULL;
    CMSampleBufferRef jpegSample = NULL;
    size_t jpegLength = metadataJPEG.length;
    if (CMBlockBufferCreateWithMemoryBlock(kCFAllocatorDefault, NULL, jpegLength, kCFAllocatorDefault,
        NULL, 0, jpegLength, 0, &jpegBlock) == noErr) {
        CMBlockBufferReplaceDataBytes(metadataJPEG.bytes, jpegBlock, 0, jpegLength);
        if (CMVideoFormatDescriptionCreate(kCFAllocatorDefault, kCMVideoCodecType_JPEG,
            (int32_t)CGImageGetWidth(snapshot.image.CGImage), (int32_t)CGImageGetHeight(snapshot.image.CGImage),
            NULL, &jpegFormat) == noErr) {
            CMSampleBufferCreateReady(kCFAllocatorDefault, jpegBlock, jpegFormat, 1, 0, NULL, 1, &jpegLength, &jpegSample);
            CFRelease(jpegFormat);
        }
        CFRelease(jpegBlock);
    }
    [(id<AVCapturePhotoCaptureDelegate>)proxy captureOutput:nil didFinishProcessingPhotoSampleBuffer:jpegSample
        previewPhotoSampleBuffer:NULL resolvedSettings:nil bracketSettings:nil error:nil];
    [self check:MSBTestHasPhotoMetadata(MSBTestImageProperties(legacy.JPEGData)) && MSBTestHasPhotoMetadata(legacy.metadata)
               name:@"旧版 JPEG 照片的数据与附件均保留 EXIF"];
    if (jpegSample) CFRelease(jpegSample);
    [(id<AVCapturePhotoCaptureDelegate>)proxy captureOutput:nil didFinishProcessingPhotoSampleBuffer:mainSample
        previewPhotoSampleBuffer:NULL resolvedSettings:nil bracketSettings:nil error:nil];
    [self check:!legacy.receivedPreviewImage name:@"旧版未请求预览时保持 nil"];
    if (mainSample) CFRelease(mainSample);
    if (previewSample) CFRelease(previewSample);

    [self checkNamedConfigurations];
    [self checkCameraPreviewWithCompletion:^{ [self checkLocation]; }];
}
- (void)checkNamedConfigurations {
    MSBSettings *settings = MSBSettings.shared;
    settings.cameraEnabled = YES;
    settings.cameraPreviewEnabled = NO;
    settings.locationEnabled = YES;
    settings.coordinate = CLLocationCoordinate2DMake(31.2304, 121.4737);
    MSBPhotoAsset *first = settings.selectedPhoto;
    [self check:![settings saveConfigurationNamed:@" \n " error:nil] &&
               ![settings saveConfigurationNamed:[@"x" stringByPaddingToLength:41 withString:@"x" startingAtIndex:0] error:nil]
               name:@"拒绝空配置名和超过 40 字符的名称"];
    [self check:[settings saveConfigurationNamed:@"  测试·配置一  " error:nil] &&
               [settings.savedConfigurationNames containsObject:@"测试·配置一"] name:@"按名称保存配置并去掉首尾空白"];
    [settings importPhotoData:[self imageData:UIColor.systemPurpleColor] error:nil];
    MSBPhotoAsset *second = settings.selectedPhoto;
    settings.cameraEnabled = NO;
    settings.cameraPreviewEnabled = YES;
    settings.locationEnabled = NO;
    settings.coordinate = CLLocationCoordinate2DMake(22.5431, 114.0579);
    [self check:[settings saveConfigurationNamed:@"测试·配置二" error:nil] name:@"可保存包含不同照片和开关的第二套配置"];
    [self check:[settings applyConfigurationNamed:@"测试·配置一" error:nil] &&
               settings.cameraEnabled && !settings.cameraPreviewEnabled && settings.locationEnabled &&
               fabs(settings.coordinate.latitude - 31.2304) < 1e-7 &&
               fabs(settings.coordinate.longitude - 121.4737) < 1e-7 &&
               [settings.selectedPhoto.JPEGData isEqualToData:first.JPEGData]
               name:@"切换配置同时恢复照片、两个相机开关、定位开关和经纬度"];
    MSBSettings *reloaded = [MSBSettings new];
    [self check:reloaded.cameraEnabled && !reloaded.cameraPreviewEnabled && reloaded.locationEnabled &&
               [reloaded.selectedPhoto.JPEGData isEqualToData:first.JPEGData] &&
               fabs(reloaded.coordinate.longitude - 121.4737) < 1e-7 &&
               [reloaded.savedConfigurationNames containsObject:@"测试·配置二"]
               name:@"配置列表和切换后的当前设置可在重新加载后恢复"];
    [self check:[settings applyConfigurationNamed:@"测试·配置二" error:nil] &&
               !settings.cameraEnabled && settings.cameraPreviewEnabled && !settings.locationEnabled &&
               fabs(settings.coordinate.latitude - 22.5431) < 1e-7 &&
               [settings.selectedPhoto.JPEGData isEqualToData:second.JPEGData]
               name:@"多套配置可往返切换且各自保留照片"];
    [self check:[settings saveConfigurationNamed:@"测试·配置一" error:nil] &&
               [settings applyConfigurationNamed:@"测试·配置一" error:nil] && settings.cameraPreviewEnabled &&
               [settings.selectedPhoto.JPEGData isEqualToData:second.JPEGData]
               name:@"同名保存更新该配置的完整快照"];
    [self check:[settings saveConfigurationNamed:@"../测试/配置" error:nil] &&
               [settings.savedConfigurationNames containsObject:@"../测试/配置"] &&
               [settings applyConfigurationNamed:@"../测试/配置" error:nil]
               name:@"名称中的斜杠和中文作为名称保存而不作为文件路径"];
    MSBPhotoAsset *before = settings.selectedPhoto;
    NSError *error = nil;
    [self check:![settings applyConfigurationNamed:@"测试·不存在的配置" error:&error] && error &&
               settings.selectedPhoto == before && settings.cameraPreviewEnabled &&
               fabs(settings.coordinate.longitude - 114.0579) < 1e-7 name:@"切换不存在的配置失败并保留当前设置"];
    NSURL *support = [NSFileManager.defaultManager URLsForDirectory:NSApplicationSupportDirectory inDomains:NSUserDomainMask].firstObject;
    NSURL *directory = [support URLByAppendingPathComponent:@"MSBTweak/Configurations" isDirectory:YES];
    NSString *fixtureName = @"测试·仅定位";
    NSString *encoded = [[fixtureName dataUsingEncoding:NSUTF8StringEncoding] base64EncodedStringWithOptions:0];
    encoded = [[encoded stringByReplacingOccurrencesOfString:@"/" withString:@"_"] stringByReplacingOccurrencesOfString:@"+" withString:@"-"];
    NSURL *fixtureURL = [directory URLByAppendingPathComponent:[encoded stringByAppendingPathExtension:@"plist"]];
    NSMutableDictionary *fixture = [@{@"version": @1, @"camera": @NO, @"cameraPreview": @NO,
        @"location": @YES, @"latitude": @35.0, @"longitude": @110.0} mutableCopy];
    [fixture writeToURL:fixtureURL atomically:YES];
    [self check:[settings applyConfigurationNamed:fixtureName error:nil] && !settings.selectedPhoto &&
               ![MSBSettings new].selectedPhoto && settings.locationEnabled &&
               [settings saveConfigurationNamed:@"测试·无照片快照" error:nil]
               name:@"不含照片的定位配置可切换和保存且清除当前照片文件"];
    [settings applyConfigurationNamed:@"测试·配置二" error:nil];
    before = settings.selectedPhoto;
    fixture[@"photo"] = [@"invalid photo" dataUsingEncoding:NSUTF8StringEncoding];
    [fixture writeToURL:fixtureURL atomically:YES];
    [self check:![settings applyConfigurationNamed:fixtureName error:nil] && settings.selectedPhoto == before &&
               settings.cameraPreviewEnabled name:@"配置照片损坏时拒绝切换且保留当前照片和开关"];
    [@{@"version": @1} writeToURL:fixtureURL atomically:YES];
    [self check:![settings applyConfigurationNamed:fixtureName error:nil] && settings.selectedPhoto == before
               name:@"配置字段不完整时拒绝切换且不修改当前设置"];
    [NSFileManager.defaultManager removeItemAtURL:fixtureURL error:nil];
    for (NSString *name in @[@"测试·编辑配置", @"测试·编辑后名称"]) {
        if ([settings.savedConfigurationNames containsObject:name]) [settings deleteConfigurationNamed:name error:nil];
    }
    [settings saveConfigurationNamed:@"测试·编辑配置" error:nil];
    settings.coordinate = CLLocationCoordinate2DMake(30.25, 120.15);
    settings.cameraPreviewEnabled = NO;
    NSUInteger countBeforeUpdate = settings.savedConfigurationNames.count;
    [self check:[settings saveConfigurationNamed:settings.currentConfigurationName error:nil] &&
               settings.savedConfigurationNames.count == countBeforeUpdate &&
               [settings applyConfigurationNamed:@"测试·编辑配置" error:nil] &&
               !settings.cameraPreviewEnabled && fabs(settings.coordinate.latitude - 30.25) < 1e-7
               name:@"编辑当前配置可覆盖保存原项且不产生新配置"];
    [self check:[settings.currentConfigurationName isEqualToString:@"测试·编辑配置"] &&
               [[MSBSettings new].currentConfigurationName isEqualToString:@"测试·编辑配置"]
               name:@"当前编辑配置名称可在重启后恢复"];
    before = settings.selectedPhoto;
    [self check:[settings renameConfigurationNamed:@"测试·编辑配置" toName:@"测试·编辑后名称" error:nil] &&
               ![settings.savedConfigurationNames containsObject:@"测试·编辑配置"] &&
               [settings.savedConfigurationNames containsObject:@"测试·编辑后名称"] &&
               [settings.currentConfigurationName isEqualToString:@"测试·编辑后名称"] && settings.selectedPhoto == before &&
               [[MSBSettings new].currentConfigurationName isEqualToString:@"测试·编辑后名称"]
               name:@"重命名更新列表和当前名称且保留配置照片与设置"];
    [self check:![settings renameConfigurationNamed:@"测试·编辑后名称" toName:@"测试·配置二" error:nil] &&
               [settings.savedConfigurationNames containsObject:@"测试·编辑后名称"]
               name:@"重命名为已有名称时拒绝覆盖其他配置"];
    [self check:![settings renameConfigurationNamed:@"测试·编辑后名称" toName:@"  " error:nil]
               name:@"拒绝将配置重命名为空白名称"];
    [self check:[settings deleteConfigurationNamed:@"测试·编辑后名称" error:nil] &&
               ![settings.savedConfigurationNames containsObject:@"测试·编辑后名称"] && !settings.currentConfigurationName &&
               settings.selectedPhoto == before && !settings.cameraPreviewEnabled &&
               fabs(settings.coordinate.latitude - 30.25) < 1e-7 && ![MSBSettings new].currentConfigurationName
               name:@"删除当前配置清除列表与编辑名称并保留正在使用的照片和设置"];
    [self check:![settings deleteConfigurationNamed:@"测试·编辑后名称" error:nil] && settings.selectedPhoto == before
               name:@"删除不存在配置失败时不修改当前照片"];
    [settings applyConfigurationNamed:@"测试·配置二" error:nil];
    // Restore the baseline expected by the camera preview checks.
    settings.cameraEnabled = YES;
    settings.cameraPreviewEnabled = NO;
    settings.locationEnabled = NO;
}
- (CALayer *)replacementOverlay:(AVCaptureVideoPreviewLayer *)preview {
    for (CALayer *layer in preview.sublayers) {
        if ([layer.name isEqualToString:@"MSBTweak.CameraReplacementPreview"]) return layer;
    }
    return nil;
}
- (void)checkCameraPreviewWithCompletion:(void (^)(void))completion {
    MSBSettings *settings = MSBSettings.shared;
    AVCaptureSession *session = [AVCaptureSession new];
    AVCaptureVideoPreviewLayer *preview = [[AVCaptureVideoPreviewLayer alloc] initWithSession:session];
    preview.frame = CGRectMake(24, 500, 300, 160);
    [self.window.rootViewController.view.layer addSublayer:preview];
    [preview setNeedsLayout];
    [preview layoutIfNeeded];
    [self check:[self replacementOverlay:preview] == nil name:@"原开关开启时保持真实相机预览"];

    settings.cameraEnabled = NO;
    settings.cameraPreviewEnabled = YES;
    MSBPhotoAsset *asset = settings.selectedPhoto;
    [self check:settings.replacementPhoto == asset name:@"仅开启含预览开关也替换拍照结果"];
    MSBSettings *reloaded = [MSBSettings new];
    [self check:reloaded.cameraPreviewEnabled && !reloaded.cameraEnabled &&
               [reloaded.replacementPhoto.JPEGData isEqualToData:asset.JPEGData] name:@"含预览开关与照片可从持久化设置恢复"];
    // Let the settings notification refresh an already displayed preview without layout.
    dispatch_async(dispatch_get_main_queue(), ^{
        CALayer *overlay = [self replacementOverlay:preview];
        [self check:overlay && overlay.contents == (__bridge id)asset.image.CGImage
                   name:@"开启后已有相机预览立即显示已选照片"];
        [self check:overlay && CGRectEqualToRect(overlay.frame, preview.bounds) &&
                   [overlay.contentsGravity isEqualToString:kCAGravityResizeAspect]
                   name:@"预览图片覆盖取景区域并匹配等比显示方式"];
        preview.videoGravity = AVLayerVideoGravityResizeAspectFill;
        [self check:[overlay.contentsGravity isEqualToString:kCAGravityResizeAspectFill]
                   name:@"预览图片跟随宿主切换等比填充"];
        preview.videoGravity = AVLayerVideoGravityResize;
        [self check:[overlay.contentsGravity isEqualToString:kCAGravityResize]
                   name:@"预览图片跟随宿主切换拉伸显示"];
        preview.bounds = CGRectMake(5, 10, 160, 300);
        [preview setNeedsLayout];
        [preview layoutIfNeeded];
        [self check:CGRectEqualToRect(overlay.frame, preview.bounds) name:@"旋转或调整预览尺寸后照片跟随布局"];

        AVCaptureVideoPreviewLayer *second = [AVCaptureVideoPreviewLayer layer];
        second.session = [AVCaptureSession new];
        second.bounds = CGRectMake(0, 0, 100, 100);
        [second setNeedsLayout];
        [second layoutIfNeeded];
        [self check:[self replacementOverlay:second].contents == (__bridge id)asset.image.CGImage
                   name:@"开关开启后新建的相机预览也显示替换照片"];
        [settings importPhotoData:[self imageData:UIColor.systemGreenColor] error:nil];
        MSBPhotoAsset *updated = settings.selectedPhoto;
        dispatch_async(dispatch_get_main_queue(), ^{
            [self check:overlay.contents == (__bridge id)updated.image.CGImage &&
                       [self replacementOverlay:second].contents == (__bridge id)updated.image.CGImage
                       name:@"切换所选照片同步刷新所有已显示预览"];
            [settings applyConfigurationNamed:@"测试·配置二" error:nil];
            MSBPhotoAsset *restored = settings.selectedPhoto;
            dispatch_async(dispatch_get_main_queue(), ^{
                [self check:restored != updated && overlay.contents == (__bridge id)restored.image.CGImage &&
                           [self replacementOverlay:second].contents == (__bridge id)restored.image.CGImage
                           name:@"切换命名配置后所有相机预览立即显示该配置的照片"];
                preview.session = nil;
                [self check:[self replacementOverlay:preview] == nil name:@"清除相机会话后移除替换预览"];
                [preview setSessionWithNoConnection:session];
                [self check:[self replacementOverlay:preview].contents == (__bridge id)restored.image.CGImage
                           name:@"无自动连接方式绑定会话后恢复替换预览"];
                settings.cameraEnabled = YES;
                settings.cameraPreviewEnabled = NO;
                dispatch_async(dispatch_get_main_queue(), ^{
                    [self check:[self replacementOverlay:preview] == nil && [self replacementOverlay:second] == nil
                               name:@"关闭含预览开关后所有取景画面恢复"];
                    [self check:settings.replacementPhoto == restored name:@"原开关仍开启时继续替换拍照结果"];
                    settings.cameraEnabled = NO;
                    [self check:settings.replacementPhoto == nil name:@"两个相机开关都关闭后停止照片替换"];
                    [preview removeFromSuperlayer];
                    completion();
                });
            });
        });
    });
}
- (void)checkLocation {
    MSBSettings *settings = MSBSettings.shared;
    settings.coordinate = CLLocationCoordinate2DMake(31.2304, 121.4737);
    CLLocationCoordinate2D before = settings.coordinate;
    settings.coordinate = CLLocationCoordinate2DMake(100, 200);
    [self check:settings.coordinate.latitude == before.latitude name:@"拒绝非法经纬度"];
    self.manager = [CLLocationManager new];
    self.manager.delegate = self;
    [self check:self.manager.delegate == self name:@"定位 delegate getter 保持宿主身份"];
    settings.locationEnabled = YES;
    [self check:fabs(self.manager.location.coordinate.latitude - before.latitude) < 1e-7 name:@"location getter 返回模拟坐标"];
    [self.manager requestLocation];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC / 2), dispatch_get_main_queue(), ^{
        [self check:self.lastLocation && fabs(self.lastLocation.coordinate.longitude - before.longitude) < 1e-7
                   name:@"requestLocation 在 RunLoop 回调模拟坐标"];
        NSUInteger count = self.locationCount;
        [self.manager requestLocation];
        [self.manager stopUpdatingLocation];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC / 4), dispatch_get_main_queue(), ^{
            [self check:self.locationCount == count name:@"stopUpdatingLocation 取消已排队的模拟回调"];
            MSBTestRequestManager *tracking = [MSBTestRequestManager new];
            tracking.delegate = self;
            [tracking requestLocation];
            MSBSettings.shared.locationEnabled = NO;
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC / 4), dispatch_get_main_queue(), ^{
                [self check:tracking.originalRequests == 1 name:@"关闭模拟后将排队单次请求交回系统"];
                MSBSettings.shared.locationEnabled = YES;
                [self checkSettingsUI];
            });
        });
    });
}
- (void)locationManager:(CLLocationManager *)manager didUpdateLocations:(NSArray<CLLocation *> *)locations {
    (void)manager;
    self.lastLocation = locations.lastObject;
    self.locationCount++;
    [self check:NSThread.isMainThread name:@"定位回调保持初始化 RunLoop 线程"];
}
- (void)locationManager:(CLLocationManager *)manager didFailWithError:(NSError *)error { (void)manager; NSLog(@"MSBTEST location error: %@", error); }
- (void)checkSettingsUI {
    [self.floatingButton sendActionsForControlEvents:UIControlEventTouchUpInside];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC), dispatch_get_main_queue(), ^{
        UINavigationController *nav = (id)self.overlayWindow.rootViewController.presentedViewController;
        [self check:[nav.topViewController isKindOfClass:MSBSettingsController.class] name:@"点击悬浮入口显示设置页"];
        MSBSettingsController *settings = (id)nav.topViewController;
        [self check:[settings.tableView numberOfRowsInSection:0] == 4 name:@"相机设置显示两个独立开关及选图入口"];
        UITableViewCell *previewCell = [settings tableView:settings.tableView
                                   cellForRowAtIndexPath:[NSIndexPath indexPathForRow:1 inSection:0]];
        UISwitch *previewToggle = (id)previewCell.accessoryView;
        previewToggle.on = YES;
        [previewToggle sendActionsForControlEvents:UIControlEventValueChanged];
        [self check:[previewCell.textLabel.text isEqualToString:@"替换拍照照片（含预览）"] &&
                   MSBSettings.shared.cameraPreviewEnabled && !MSBSettings.shared.cameraEnabled
                   name:@"新增 UI 开关可独立启用预览与拍照替换"];
        previewToggle.on = NO;
        [previewToggle sendActionsForControlEvents:UIControlEventValueChanged];
        UITableViewCell *importCell = [settings tableView:settings.tableView
                                  cellForRowAtIndexPath:[NSIndexPath indexPathForRow:2 inSection:0]];
        [self check:[importCell.textLabel.text isEqualToString:@"从相册选择替换照片"] name:@"追加开关后选图入口位置正确"];
        [self checkConfigurationUI:settings completion:^{
            NSIndexPath *mapRow = [NSIndexPath indexPathForRow:1 inSection:1];
            [settings.tableView.delegate tableView:settings.tableView didSelectRowAtIndexPath:mapRow];
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC), dispatch_get_main_queue(), ^{
                [self check:[nav.topViewController.title isEqualToString:@"选择模拟位置"] name:@"位置入口可以打开地图选择页"];
                settings.onClose();
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC), dispatch_get_main_queue(), ^{
                    [self check:self.window.isKeyWindow && !self.overlayWindow.isKeyWindow name:@"关闭设置后恢复宿主 keyWindow"];
                    [self.floatingButton sendActionsForControlEvents:UIControlEventTouchUpInside];
                    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC), dispatch_get_main_queue(), ^{
                        UINavigationController *reopened = (id)self.overlayWindow.rootViewController.presentedViewController;
                        [self check:[reopened.topViewController isKindOfClass:MSBSettingsController.class]
                                   name:@"保存配置并关闭后点击悬浮图标可以再次进入设置页"];
                        MSBSettingsController *reopenedSettings = (id)reopened.topViewController;
                        if (reopenedSettings.onClose) reopenedSettings.onClose();
                        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC), dispatch_get_main_queue(), ^{
                            [self finish];
                        });
                    });
                });
            });
        }];
    });
}
// UIKit can dismiss an alert before its action handler runs. Reproduce that
// ordering instead of invoking handlers while their alert is still presented.
- (void)activateAlert:(UIAlertController *)alert actionNamed:(NSString *)title {
    for (UIAlertAction *action in alert.actions) {
        if (![action.title isEqualToString:title]) continue;
        void (^handler)(UIAlertAction *) = [action valueForKey:@"handler"];
        [alert dismissViewControllerAnimated:YES completion:^{
            if (handler) handler(action);
        }];
        return;
    }
}
- (void)checkConfigurationUI:(MSBSettingsController *)controller completion:(void (^)(void))completion {
    MSBSettings *settings = MSBSettings.shared;
    NSArray *names = settings.savedConfigurationNames;
    [self check:[controller.tableView numberOfSections] == 3 &&
               [controller.tableView numberOfRowsInSection:2] == (NSInteger)names.count + 1
               name:@"配置管理列出保存入口和全部已命名配置"];
    NSUInteger index = [names indexOfObject:@"测试·配置二"];
    if (index != NSNotFound) {
        NSIndexPath *row = [NSIndexPath indexPathForRow:(NSInteger)index + 1 inSection:2];
        [controller tableView:controller.tableView didSelectRowAtIndexPath:row];
    }
    [self check:index != NSNotFound && settings.cameraPreviewEnabled && !settings.cameraEnabled &&
               !settings.locationEnabled && fabs(settings.coordinate.latitude - 22.5431) < 1e-7
               name:@"点击配置名称切换该配置的照片和设置"];
    settings.cameraPreviewEnabled = NO;
    [controller tableView:controller.tableView didSelectRowAtIndexPath:[NSIndexPath indexPathForRow:0 inSection:2]];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC / 2), dispatch_get_main_queue(), ^{
        UIAlertController *prompt = (id)controller.presentedViewController;
        [self check:[prompt isKindOfClass:UIAlertController.class] && prompt.textFields.count == 1 &&
                   [prompt.title isEqualToString:@"保存当前配置"] name:@"保存入口弹出配置名称输入框"];
        prompt.textFields.firstObject.text = @"测试·配置二";
        [self activateAlert:prompt actionNamed:@"保存"];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC), dispatch_get_main_queue(), ^{
            UIAlertController *confirm = (id)controller.presentedViewController;
            [self check:[confirm.title isEqualToString:@"覆盖已有配置？"] name:@"UI 保存同名配置前显示覆盖确认"];
            BOOL applied = [settings applyConfigurationNamed:@"测试·配置二" error:nil];
            [self check:applied && settings.cameraPreviewEnabled name:@"覆盖确认前原有配置保持不变"];
            settings.cameraPreviewEnabled = NO;
            [self activateAlert:confirm actionNamed:@"覆盖"];
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC), dispatch_get_main_queue(), ^{
                BOOL updated = [settings applyConfigurationNamed:@"测试·配置二" error:nil];
                [self check:updated && !controller.presentedViewController && !settings.cameraPreviewEnabled &&
                           self.overlayWindow.rootViewController.presentedViewController == controller.navigationController
                           name:@"确认覆盖后只关闭弹窗且设置页保持打开"];
                [self checkConfigurationEditingUI:controller completion:completion];
            });
        });
    });
}
- (void)runUISteps:(NSArray<dispatch_block_t> *)steps completion:(dispatch_block_t)completion {
    if (steps.count == 0) { completion(); return; }
    steps.firstObject();
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC * 4 / 5), dispatch_get_main_queue(), ^{
        [self runUISteps:[steps subarrayWithRange:NSMakeRange(1, steps.count - 1)] completion:completion];
    });
}
- (void)showConfigurationMenu:(NSString *)name controller:(MSBSettingsController *)controller {
    NSUInteger index = [MSBSettings.shared.savedConfigurationNames indexOfObject:name];
    if (index == NSNotFound) { [self check:NO name:@"编辑菜单对应配置存在"]; return; }
    [controller tableView:controller.tableView accessoryButtonTappedForRowWithIndexPath:
        [NSIndexPath indexPathForRow:(NSInteger)index + 1 inSection:2]];
}
- (void)checkConfigurationEditingUI:(MSBSettingsController *)controller completion:(dispatch_block_t)completion {
    MSBSettings *settings = MSBSettings.shared;
    NSString *name = @"测试·界面编辑", *renamed = @"测试·界面重命名";
    for (NSString *fixture in @[name, renamed]) {
        if ([settings.savedConfigurationNames containsObject:fixture]) [settings deleteConfigurationNamed:fixture error:nil];
    }
    NSString *originalName = settings.currentConfigurationName;
    __block MSBPhotoAsset *photoBeforeDeletion;
    NSArray<dispatch_block_t> *steps = @[
        ^{
            [controller tableView:controller.tableView didSelectRowAtIndexPath:[NSIndexPath indexPathForRow:0 inSection:2]];
        },
        ^{
            UIAlertController *prompt = (id)controller.presentedViewController;
            [self check:[prompt.textFields.firstObject.text isEqualToString:originalName]
                       name:@"保存配置自动填入当前名称以便编辑原配置"];
            prompt.textFields.firstObject.text = name;
            [self activateAlert:prompt actionNamed:@"保存"];
        },
        ^{
            [self check:[settings.savedConfigurationNames containsObject:name] &&
                       [settings.currentConfigurationName isEqualToString:name] &&
                       self.overlayWindow.rootViewController.presentedViewController == controller.navigationController &&
                       !controller.presentedViewController name:@"另存新配置成功后设置页仍保持打开"];
            settings.cameraPreviewEnabled = YES;
            settings.coordinate = CLLocationCoordinate2DMake(32.5, 118.5);
            [self showConfigurationMenu:name controller:controller];
        },
        ^{
            UIAlertController *menu = (id)controller.presentedViewController;
            NSArray *titles = [menu.actions valueForKey:@"title"];
            [self check:[titles containsObject:@"加载并编辑"] && [titles containsObject:@"用当前设置更新"] &&
                       [titles containsObject:@"重命名"] && [titles containsObject:@"删除配置"]
                       name:@"配置右侧菜单提供编辑、更新、重命名和删除入口"];
            [self activateAlert:menu actionNamed:@"用当前设置更新"];
        },
        ^{
            UIAlertController *confirm = (id)controller.presentedViewController;
            [self check:[confirm.title isEqualToString:@"覆盖已有配置？"] name:@"从编辑菜单更新配置仍需覆盖确认"];
            [self activateAlert:confirm actionNamed:@"覆盖"];
        },
        ^{
            settings.cameraPreviewEnabled = NO;
            [self check:[settings applyConfigurationNamed:name error:nil] && settings.cameraPreviewEnabled &&
                       fabs(settings.coordinate.latitude - 32.5) < 1e-7 name:@"编辑菜单将当前照片、开关和坐标保存到原配置"];
            [self showConfigurationMenu:name controller:controller];
        },
        ^{ [self activateAlert:(id)controller.presentedViewController actionNamed:@"重命名"]; },
        ^{
            UIAlertController *prompt = (id)controller.presentedViewController;
            [self check:[prompt.title isEqualToString:@"重命名配置"] && [prompt.textFields.firstObject.text isEqualToString:name]
                       name:@"重命名弹窗填入原配置名称"];
            prompt.textFields.firstObject.text = renamed;
            [self activateAlert:prompt actionNamed:@"保存"];
        },
        ^{
            [self check:![settings.savedConfigurationNames containsObject:name] &&
                       [settings.savedConfigurationNames containsObject:renamed] &&
                       [settings.currentConfigurationName isEqualToString:renamed] name:@"重命名后列表和当前编辑名称同步更新"];
            photoBeforeDeletion = settings.selectedPhoto;
            [self showConfigurationMenu:renamed controller:controller];
        },
        ^{ [self activateAlert:(id)controller.presentedViewController actionNamed:@"删除配置"]; },
        ^{
            UIAlertController *confirm = (id)controller.presentedViewController;
            [self check:[confirm.title isEqualToString:@"删除配置？"] && [settings.savedConfigurationNames containsObject:renamed]
                       name:@"删除配置前显示确认且保留原配置"];
            [self activateAlert:confirm actionNamed:@"取消"];
        },
        ^{
            [self check:[settings.savedConfigurationNames containsObject:renamed] name:@"取消删除后配置仍然存在"];
            [self showConfigurationMenu:renamed controller:controller];
        },
        ^{ [self activateAlert:(id)controller.presentedViewController actionNamed:@"删除配置"]; },
        ^{ [self activateAlert:(id)controller.presentedViewController actionNamed:@"删除"]; },
        ^{
            [self check:![settings.savedConfigurationNames containsObject:renamed] && !settings.currentConfigurationName &&
                       settings.selectedPhoto == photoBeforeDeletion && settings.cameraPreviewEnabled &&
                       self.overlayWindow.rootViewController.presentedViewController == controller.navigationController &&
                       !controller.presentedViewController name:@"确认删除后移除配置并保持当前设置和设置页可用"];
        }
    ];
    [self runUISteps:steps completion:completion];
}
- (void)finish {
    NSUInteger failed = 0;
    for (NSDictionary *result in self.results) if (![result[@"passed"] boolValue]) failed++;
    NSDictionary *report = @{@"passed": @(self.results.count - failed), @"failed": @(failed), @"checks": self.results};
    NSData *data = [NSJSONSerialization dataWithJSONObject:report options:NSJSONWritingPrettyPrinted error:nil];
    NSURL *url = [[[NSFileManager defaultManager] URLsForDirectory:NSDocumentDirectory inDomains:NSUserDomainMask].firstObject
                  URLByAppendingPathComponent:@"test-results.json"];
    [data writeToURL:url atomically:YES];
    self.status.text = [NSString stringWithFormat:@"MSBTweak 测试完成\n通过 %lu 项，失败 %lu 项\n\n宿主按钮仍可交互。", (unsigned long)(self.results.count - failed), (unsigned long)failed];
    NSLog(@"MSBTEST COMPLETE %@", report);
    [self.floatingButton sendActionsForControlEvents:UIControlEventTouchUpInside];
}
@end

int main(int argc, char *argv[]) {
    @autoreleasepool { return UIApplicationMain(argc, argv, nil, NSStringFromClass(MSBTestAppDelegate.class)); }
}
