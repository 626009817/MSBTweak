#import "MSBTweakHooks.h"
#import "MSBTweakSettings.h"
#import <AVFoundation/AVFoundation.h>
#import <CoreImage/CoreImage.h>
#import <ImageIO/ImageIO.h>
#import <objc/runtime.h>

static char MSBPhotoKey, MSBPixelBufferKey, MSBPreviewPixelBufferKey, MSBFileDataKey, MSBPendingCapturesKey;

static CIContext *MSBImageContext(void) {
    static CIContext *context;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{ context = [CIContext contextWithOptions:@{kCIContextCacheIntermediates: @NO}]; });
    return context;
}

@interface MSBPixelBuffer : NSObject
@property(nonatomic, readonly) CVPixelBufferRef buffer;
- (instancetype)initWithAsset:(MSBPhotoAsset *)asset matchingBuffer:(CVPixelBufferRef)original;
@end

@implementation MSBPixelBuffer
- (instancetype)initWithAsset:(MSBPhotoAsset *)asset matchingBuffer:(CVPixelBufferRef)original {
    if (!original || !asset.image.CGImage) return nil;
    if ((self = [super init])) {
        size_t width = CVPixelBufferGetWidth(original), height = CVPixelBufferGetHeight(original);
        NSDictionary *attributes = @{(id)kCVPixelBufferIOSurfacePropertiesKey: @{}};
        if (CVPixelBufferCreate(kCFAllocatorDefault, width, height, CVPixelBufferGetPixelFormatType(original),
                               (__bridge CFDictionaryRef)attributes, &_buffer) != kCVReturnSuccess) return nil;
        CVBufferPropagateAttachments(original, _buffer);
        @try {
            CIImage *image = [CIImage imageWithCGImage:asset.image.CGImage];
            CGRect extent = image.extent;
            if (CGRectIsEmpty(extent) || CGRectIsInfinite(extent)) return nil;
            image = [image imageByApplyingTransform:CGAffineTransformMakeScale(width / extent.size.width,
                                                                             height / extent.size.height)];
            CIRenderDestination *destination = [[CIRenderDestination alloc] initWithPixelBuffer:_buffer];
            // CVPixelBuffer's first row is the top row of the normalized image.
            destination.flipped = YES;
            CGColorSpaceRef colorSpace = CVImageBufferGetColorSpace(original);
            if (colorSpace) destination.colorSpace = colorSpace;
            NSError *error = nil;
            CIRenderTask *task = [MSBImageContext() startTaskToRender:image toDestination:destination error:&error];
            if (!task || ![task waitUntilCompletedAndReturnError:&error]) return nil;
            NSDictionary *metadata = MSBPhotoMetadataForSize(asset.metadata, width, height);
            CVBufferSetAttachments(_buffer, (__bridge CFDictionaryRef)metadata, kCVAttachmentMode_ShouldPropagate);
        } @catch (__unused NSException *exception) {
            // Unsupported destination formats must not turn a host capture into an exception.
            return nil;
        }
    }
    return self;
}
- (void)dealloc {
    if (_buffer) CVPixelBufferRelease(_buffer);
}
@end

static MSBPhotoAsset *MSBAssetForPhoto(AVCapturePhoto *photo) {
    id value = objc_getAssociatedObject(photo, &MSBPhotoKey);
    return [value isKindOfClass:MSBPhotoAsset.class] ? value : nil;
}

static void MSBAttachAsset(AVCapturePhoto *photo, MSBPhotoAsset *asset) {
    if (photo && asset) objc_setAssociatedObject(photo, &MSBPhotoKey, asset, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

static NSData *MSBEncodePhoto(MSBPhotoAsset *asset, NSString *type) {
    if ([type isEqualToString:@"public.jpeg"]) return asset.JPEGData;
    if (![type isEqualToString:@"public.heic"] && ![type isEqualToString:@"public.heif"] &&
        ![type isEqualToString:@"public.png"]) return nil;
    NSMutableData *data = [NSMutableData data];
    CGImageDestinationRef destination = CGImageDestinationCreateWithData((__bridge CFMutableDataRef)data,
        (__bridge CFStringRef)type, 1, NULL);
    if (!destination) return nil;
    NSMutableDictionary *metadata = [asset.metadata mutableCopy];
    metadata[(id)kCGImageDestinationLossyCompressionQuality] = @0.95;
    CGImageDestinationAddImage(destination, asset.image.CGImage, (__bridge CFDictionaryRef)metadata);
    BOOL success = CGImageDestinationFinalize(destination);
    CFRelease(destination);
    return success ? [data copy] : nil;
}

static NSData *MSBReplacementFileData(AVCapturePhoto *photo, NSData *original) {
    MSBPhotoAsset *asset = MSBAssetForPhoto(photo);
    if (!asset || !original) return original;
    CGImageSourceRef source = CGImageSourceCreateWithData((__bridge CFDataRef)original, NULL);
    if (!source) return original;
    NSString *type = [(__bridge NSString *)CGImageSourceGetType(source) copy];
    CFRelease(source);
    if (!type) return original;
    @synchronized (photo) {
        NSMutableDictionary *cache = objc_getAssociatedObject(photo, &MSBFileDataKey);
        if (!cache) {
            cache = [NSMutableDictionary dictionary];
            objc_setAssociatedObject(photo, &MSBFileDataKey, cache, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
        id value = cache[type];
        if (!value) {
            value = MSBEncodePhoto(asset, type) ?: NSNull.null;
            cache[type] = value;
        }
        return [value isKindOfClass:NSData.class] ? value : original;
    }
}

static MSBPixelBuffer *MSBReplacementBuffer(AVCapturePhoto *photo, CVPixelBufferRef original, const void *key) {
    MSBPhotoAsset *asset = MSBAssetForPhoto(photo);
    if (!asset || !original) return nil;
    @synchronized (photo) {
        id value = objc_getAssociatedObject(photo, key);
        if (!value) {
            value = [[MSBPixelBuffer alloc] initWithAsset:asset matchingBuffer:original] ?: (id)NSNull.null;
            objc_setAssociatedObject(photo, key, value, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
        return [value isKindOfClass:MSBPixelBuffer.class] ? value : nil;
    }
}

static CMSampleBufferRef MSBCreateJPEGSample(MSBPhotoAsset *asset, CMSampleBufferRef original) CF_RETURNS_RETAINED;
static CMSampleBufferRef MSBCreateJPEGSample(MSBPhotoAsset *asset, CMSampleBufferRef original) {
    CMBlockBufferRef block = NULL;
    CMVideoFormatDescriptionRef format = NULL;
    CMSampleBufferRef sample = NULL;
    size_t length = asset.JPEGData.length;
    OSStatus status = CMBlockBufferCreateWithMemoryBlock(kCFAllocatorDefault, NULL, length,
        kCFAllocatorDefault, NULL, 0, length, 0, &block);
    if (status != noErr) return NULL;
    status = CMBlockBufferReplaceDataBytes(asset.JPEGData.bytes, block, 0, length);
    if (status == noErr) status = CMVideoFormatDescriptionCreate(kCFAllocatorDefault, kCMVideoCodecType_JPEG,
        (int32_t)CGImageGetWidth(asset.image.CGImage), (int32_t)CGImageGetHeight(asset.image.CGImage), NULL, &format);
    CMSampleTimingInfo timing = {kCMTimeInvalid, kCMTimeInvalid, kCMTimeInvalid};
    if (original) CMSampleBufferGetSampleTimingInfo(original, 0, &timing);
    if (status == noErr) status = CMSampleBufferCreateReady(kCFAllocatorDefault, block, format, 1, 1,
                                                         &timing, 1, &length, &sample);
    if (format) CFRelease(format);
    CFRelease(block);
    if (status != noErr) {
        if (sample) CFRelease(sample);
        return NULL;
    }
    CMSetAttachments(sample, (__bridge CFDictionaryRef)asset.metadata, kCMAttachmentMode_ShouldPropagate);
    return sample;
}

static CMSampleBufferRef MSBCreateReplacementSample(MSBPhotoAsset *asset, CMSampleBufferRef original,
                                                 BOOL allowJPEG) CF_RETURNS_RETAINED;
static CMSampleBufferRef MSBCreateReplacementSample(MSBPhotoAsset *asset, CMSampleBufferRef original, BOOL allowJPEG) {
    if (!original) return NULL;
    CMFormatDescriptionRef originalFormat = CMSampleBufferGetFormatDescription(original);
    if (!originalFormat || CMFormatDescriptionGetMediaType(originalFormat) != kCMMediaType_Video) return NULL;
    if (CMFormatDescriptionGetMediaSubType(originalFormat) == kCMVideoCodecType_JPEG) {
        return allowJPEG ? MSBCreateJPEGSample(asset, original) : NULL;
    }
    CVPixelBufferRef originalBuffer = CMSampleBufferGetImageBuffer(original);
    if (!originalBuffer) return NULL;
    MSBPixelBuffer *holder = [[MSBPixelBuffer alloc] initWithAsset:asset matchingBuffer:originalBuffer];
    if (!holder) return NULL;
    CMVideoFormatDescriptionRef format = NULL;
    CMSampleBufferRef sample = NULL;
    OSStatus status = CMVideoFormatDescriptionCreateForImageBuffer(kCFAllocatorDefault, holder.buffer, &format);
    CMSampleTimingInfo timing = {kCMTimeInvalid, kCMTimeInvalid, kCMTimeInvalid};
    CMSampleBufferGetSampleTimingInfo(original, 0, &timing);
    if (status == noErr) status = CMSampleBufferCreateReadyWithImageBuffer(kCFAllocatorDefault, holder.buffer,
                                                                        format, &timing, &sample);
    if (format) CFRelease(format);
    if (status != noErr) {
        if (sample) CFRelease(sample);
        return NULL;
    }
    NSDictionary *metadata = MSBPhotoMetadataForSize(asset.metadata, CVPixelBufferGetWidth(holder.buffer),
                                                   CVPixelBufferGetHeight(holder.buffer));
    CMSetAttachments(sample, (__bridge CFDictionaryRef)metadata, kCMAttachmentMode_ShouldPropagate);
    return sample;
}

@interface AVCapturePhoto (MSBTweak)
- (NSData *)msb_fileDataRepresentation;
- (NSData *)msb_fileDataRepresentationWithCustomizer:(id)customizer;
- (CGImageRef)msb_CGImageRepresentation;
- (CGImageRef)msb_previewCGImageRepresentation;
- (CVPixelBufferRef)msb_pixelBuffer;
- (CVPixelBufferRef)msb_previewPixelBuffer;
- (NSDictionary *)msb_metadata;
@end

@implementation AVCapturePhoto (MSBTweak)
- (NSData *)msb_fileDataRepresentation {
    return MSBReplacementFileData(self, [self msb_fileDataRepresentation]);
}
- (NSData *)msb_fileDataRepresentationWithCustomizer:(id)customizer {
    return MSBReplacementFileData(self, [self msb_fileDataRepresentationWithCustomizer:customizer]);
}
- (CGImageRef)msb_CGImageRepresentation {
    MSBPhotoAsset *asset = MSBAssetForPhoto(self);
    return asset ? asset.image.CGImage : [self msb_CGImageRepresentation];
}
- (CGImageRef)msb_previewCGImageRepresentation {
    CGImageRef original = [self msb_previewCGImageRepresentation];
    MSBPhotoAsset *asset = MSBAssetForPhoto(self);
    return asset && original ? asset.image.CGImage : original;
}
- (CVPixelBufferRef)msb_pixelBuffer {
    CVPixelBufferRef original = [self msb_pixelBuffer];
    MSBPixelBuffer *holder = MSBReplacementBuffer(self, original, &MSBPixelBufferKey);
    return holder ? holder.buffer : original;
}
- (CVPixelBufferRef)msb_previewPixelBuffer {
    CVPixelBufferRef original = [self msb_previewPixelBuffer];
    MSBPixelBuffer *holder = MSBReplacementBuffer(self, original, &MSBPreviewPixelBufferKey);
    return holder ? holder.buffer : original;
}
- (NSDictionary *)msb_metadata {
    MSBPhotoAsset *asset = MSBAssetForPhoto(self);
    if (!asset) return [self msb_metadata];
    return asset.metadata;
}
@end

@interface MSBPhotoDelegate : NSObject <AVCapturePhotoCaptureDelegate>
@property(nonatomic, strong) id<AVCapturePhotoCaptureDelegate> target;
@property(nonatomic, strong) MSBPhotoAsset *asset;
@property(nonatomic, weak) AVCapturePhotoOutput *output;
@end

@implementation MSBPhotoDelegate
- (BOOL)respondsToSelector:(SEL)selector {
    // Advertising the modern callback would prevent AVFoundation calling a legacy-only delegate.
    if (selector == @selector(captureOutput:didFinishProcessingPhoto:error:) ||
        selector == NSSelectorFromString(@"captureOutput:didFinishCapturingDeferredPhotoProxy:error:") ||
        selector == @selector(captureOutput:didFinishProcessingPhotoSampleBuffer:previewPhotoSampleBuffer:resolvedSettings:bracketSettings:error:)) {
        return [self.target respondsToSelector:selector];
    }
    return [super respondsToSelector:selector] || [self.target respondsToSelector:selector];
}
- (id)forwardingTargetForSelector:(SEL)selector {
    return [self.target respondsToSelector:selector] ? self.target : [super forwardingTargetForSelector:selector];
}
- (void)captureOutput:(AVCapturePhotoOutput *)output didFinishProcessingPhoto:(AVCapturePhoto *)photo error:(NSError *)error {
    if (!error && !photo.isRawPhoto) MSBAttachAsset(photo, self.asset);
    if ([self.target respondsToSelector:_cmd]) [self.target captureOutput:output didFinishProcessingPhoto:photo error:error];
}
- (void)captureOutput:(AVCapturePhotoOutput *)output didFinishCapturingDeferredPhotoProxy:(AVCaptureDeferredPhotoProxy *)photo
               error:(NSError *)error API_AVAILABLE(ios(17.0)) {
    if (!error) MSBAttachAsset(photo, self.asset);
    if ([self.target respondsToSelector:_cmd]) [self.target captureOutput:output didFinishCapturingDeferredPhotoProxy:photo error:error];
}
- (void)captureOutput:(AVCapturePhotoOutput *)output
        didFinishProcessingPhotoSampleBuffer:(CMSampleBufferRef)photoSampleBuffer
        previewPhotoSampleBuffer:(CMSampleBufferRef)previewPhotoSampleBuffer
        resolvedSettings:(AVCaptureResolvedPhotoSettings *)resolvedSettings
        bracketSettings:(AVCaptureBracketedStillImageSettings *)bracketSettings error:(NSError *)error {
    CMSampleBufferRef replacement = !error ? MSBCreateReplacementSample(self.asset, photoSampleBuffer, YES) : NULL;
    CMSampleBufferRef preview = !error ? MSBCreateReplacementSample(self.asset, previewPhotoSampleBuffer, NO) : NULL;
    @try {
        if ([self.target respondsToSelector:_cmd]) {
            [self.target captureOutput:output didFinishProcessingPhotoSampleBuffer:replacement ?: photoSampleBuffer
                previewPhotoSampleBuffer:preview ?: previewPhotoSampleBuffer resolvedSettings:resolvedSettings
                bracketSettings:bracketSettings error:error];
        }
    } @finally {
        if (preview) CFRelease(preview);
        if (replacement) CFRelease(replacement);
    }
}
- (void)captureOutput:(AVCapturePhotoOutput *)output didFinishCaptureForResolvedSettings:(AVCaptureResolvedPhotoSettings *)resolvedSettings
               error:(NSError *)error {
    @try {
        if ([self.target respondsToSelector:_cmd]) [self.target captureOutput:output didFinishCaptureForResolvedSettings:resolvedSettings error:error];
    } @finally {
        @synchronized (output) {
            [objc_getAssociatedObject(output, &MSBPendingCapturesKey) removeObject:self];
        }
    }
}
@end

@interface AVCapturePhotoOutput (MSBTweak)
- (void)msb_capturePhotoWithSettings:(AVCapturePhotoSettings *)settings delegate:(id<AVCapturePhotoCaptureDelegate>)delegate;
@end
@implementation AVCapturePhotoOutput (MSBTweak)
- (void)msb_capturePhotoWithSettings:(AVCapturePhotoSettings *)settings delegate:(id<AVCapturePhotoCaptureDelegate>)delegate {
    MSBPhotoAsset *asset = MSBSettings.shared.replacementPhoto;
    if (!asset || !delegate) {
        [self msb_capturePhotoWithSettings:settings delegate:delegate];
        return;
    }
    MSBPhotoDelegate *proxy = [MSBPhotoDelegate new];
    proxy.target = delegate;
    proxy.asset = asset;
    proxy.output = self;
    @synchronized (self) {
        NSMutableSet *pending = objc_getAssociatedObject(self, &MSBPendingCapturesKey);
        if (!pending) {
            pending = [NSMutableSet set];
            objc_setAssociatedObject(self, &MSBPendingCapturesKey, pending, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
        [pending addObject:proxy];
    }
    @try {
        [self msb_capturePhotoWithSettings:settings delegate:proxy];
    } @catch (NSException *exception) {
        @synchronized (self) { [objc_getAssociatedObject(self, &MSBPendingCapturesKey) removeObject:proxy]; }
        @throw exception;
    }
}
@end

@interface AVCaptureStillImageOutput (MSBTweak)
- (void)msb_captureStillImageAsynchronouslyFromConnection:(AVCaptureConnection *)connection
                                     completionHandler:(void (^)(CMSampleBufferRef, NSError *))handler;
@end
@implementation AVCaptureStillImageOutput (MSBTweak)
- (void)msb_captureStillImageAsynchronouslyFromConnection:(AVCaptureConnection *)connection
                                     completionHandler:(void (^)(CMSampleBufferRef, NSError *))handler {
    MSBPhotoAsset *asset = MSBSettings.shared.replacementPhoto;
    if (!asset || !handler) {
        [self msb_captureStillImageAsynchronouslyFromConnection:connection completionHandler:handler];
        return;
    }
    [self msb_captureStillImageAsynchronouslyFromConnection:connection completionHandler:^(CMSampleBufferRef sample, NSError *error) {
        CMSampleBufferRef replacement = !error ? MSBCreateReplacementSample(asset, sample, YES) : NULL;
        @try {
            handler(replacement ?: sample, error);
        } @finally {
            if (replacement) CFRelease(replacement);
        }
    }];
}
@end

void MSBInstallCameraHooks(void) {
    MSBInstallCameraPreviewHooks();
    MSBSwizzle(AVCapturePhotoOutput.class, @selector(capturePhotoWithSettings:delegate:), @selector(msb_capturePhotoWithSettings:delegate:));
    MSBSwizzle(AVCapturePhoto.class, @selector(fileDataRepresentation), @selector(msb_fileDataRepresentation));
    MSBSwizzle(AVCapturePhoto.class, @selector(fileDataRepresentationWithCustomizer:), @selector(msb_fileDataRepresentationWithCustomizer:));
    MSBSwizzle(AVCapturePhoto.class, @selector(CGImageRepresentation), @selector(msb_CGImageRepresentation));
    MSBSwizzle(AVCapturePhoto.class, @selector(previewCGImageRepresentation), @selector(msb_previewCGImageRepresentation));
    MSBSwizzle(AVCapturePhoto.class, @selector(pixelBuffer), @selector(msb_pixelBuffer));
    MSBSwizzle(AVCapturePhoto.class, @selector(previewPixelBuffer), @selector(msb_previewPixelBuffer));
    MSBSwizzle(AVCapturePhoto.class, @selector(metadata), @selector(msb_metadata));
    MSBSwizzle(AVCaptureStillImageOutput.class, @selector(captureStillImageAsynchronouslyFromConnection:completionHandler:),
              @selector(msb_captureStillImageAsynchronouslyFromConnection:completionHandler:));
}
