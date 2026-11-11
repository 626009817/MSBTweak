#import "MSBTweakSettings.h"
#import <ImageIO/ImageIO.h>

NSNotificationName const MSBSettingsDidChangeNotification = @"MSBTweak.SettingsDidChange";
static NSString *const MSBPrefsKey = @"MSBTweak.Preferences.v1";

static BOOL MSBSettingsError(NSError **error, NSString *message) {
    if (error) *error = [NSError errorWithDomain:@"MSBTweak" code:3
                                      userInfo:@{NSLocalizedDescriptionKey: message}];
    return NO;
}

static NSString *MSBConfigurationName(NSString *name) {
    NSString *trimmed = [name stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    return trimmed.length > 0 && trimmed.length <= 40 ? trimmed : nil;
}

NSDictionary *MSBPhotoMetadataForSize(NSDictionary *metadata, size_t width, size_t height) {
    NSMutableDictionary *properties = [metadata mutableCopy];
    properties[(id)kCGImagePropertyOrientation] = @1;
    properties[(id)kCGImagePropertyPixelWidth] = @(width);
    properties[(id)kCGImagePropertyPixelHeight] = @(height);
    [properties removeObjectForKey:(id)kCGImagePropertyFileSize];
    NSMutableDictionary *exif = [properties[(id)kCGImagePropertyExifDictionary] mutableCopy];
    if (exif) {
        exif[(id)kCGImagePropertyExifPixelXDimension] = @(width);
        exif[(id)kCGImagePropertyExifPixelYDimension] = @(height);
        properties[(id)kCGImagePropertyExifDictionary] = [exif copy];
    }
    NSMutableDictionary *tiff = [properties[(id)kCGImagePropertyTIFFDictionary] mutableCopy];
    if (tiff) {
        tiff[(id)kCGImagePropertyTIFFOrientation] = @1;
        properties[(id)kCGImagePropertyTIFFDictionary] = [tiff copy];
    }
    return [properties copy];
}

@implementation MSBPhotoAsset
- (instancetype)initWithImage:(UIImage *)image data:(NSData *)data {
    if ((self = [super init])) {
        _image = image;
        _JPEGData = [data copy];
        CGImageSourceRef source = CGImageSourceCreateWithData((__bridge CFDataRef)data, NULL);
        NSDictionary *properties = source ? CFBridgingRelease(CGImageSourceCopyPropertiesAtIndex(source, 0, NULL)) : nil;
        if (source) CFRelease(source);
        _metadata = MSBPhotoMetadataForSize(properties ?: @{}, CGImageGetWidth(image.CGImage), CGImageGetHeight(image.CGImage));
    }
    return self;
}
@end

@implementation MSBSettings {
    NSLock *_lock;
    MSBPhotoAsset *_photo;
    BOOL _cameraEnabled;
    BOOL _cameraPreviewEnabled;
    BOOL _locationEnabled;
    CLLocationCoordinate2D _coordinate;
    NSString *_currentConfigurationName;
}

+ (instancetype)shared {
    static MSBSettings *instance;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{ instance = [self new]; });
    return instance;
}

- (NSURL *)photoURL {
    NSURL *base = [[NSFileManager defaultManager] URLsForDirectory:NSApplicationSupportDirectory
                                                      inDomains:NSUserDomainMask].firstObject;
    return [[base URLByAppendingPathComponent:@"MSBTweak" isDirectory:YES]
            URLByAppendingPathComponent:@"replacement.jpg"];
}

- (instancetype)init {
    if ((self = [super init])) {
        _lock = [NSLock new];
        NSDictionary *prefs = [[NSUserDefaults standardUserDefaults] dictionaryForKey:MSBPrefsKey];
        _cameraEnabled = [prefs[@"camera"] boolValue];
        _cameraPreviewEnabled = [prefs[@"cameraPreview"] boolValue];
        _locationEnabled = [prefs[@"location"] boolValue];
        _coordinate = CLLocationCoordinate2DMake(39.9042, 116.4074);
        if (prefs[@"latitude"] && prefs[@"longitude"]) {
            CLLocationCoordinate2D coordinate = CLLocationCoordinate2DMake([prefs[@"latitude"] doubleValue],
                                                                          [prefs[@"longitude"] doubleValue]);
            if (CLLocationCoordinate2DIsValid(coordinate)) _coordinate = coordinate;
        }
        NSData *data = [NSData dataWithContentsOfURL:[self photoURL]];
        UIImage *image = data ? [UIImage imageWithData:data] : nil;
        if (image) _photo = [[MSBPhotoAsset alloc] initWithImage:image data:data];
        if (!_photo) { _cameraEnabled = NO; _cameraPreviewEnabled = NO; }
        NSString *name = [prefs[@"configuration"] isKindOfClass:NSString.class] ? MSBConfigurationName(prefs[@"configuration"]) : nil;
        if (name && [NSFileManager.defaultManager fileExistsAtPath:[self configurationURLForName:name].path]) {
            _currentConfigurationName = [name copy];
        }
    }
    return self;
}

// Called with the lock held so concurrent changes cannot persist an older snapshot.
- (void)saveLocked {
    [[NSUserDefaults standardUserDefaults] setObject:@{
        @"camera": @(_cameraEnabled), @"cameraPreview": @(_cameraPreviewEnabled),
        @"location": @(_locationEnabled), @"configuration": _currentConfigurationName ?: @"",
        @"latitude": @(_coordinate.latitude), @"longitude": @(_coordinate.longitude)
    } forKey:MSBPrefsKey];
}

- (void)notifyChanged {
    dispatch_async(dispatch_get_main_queue(), ^{
        [[NSNotificationCenter defaultCenter] postNotificationName:MSBSettingsDidChangeNotification object:self];
    });
}

- (BOOL)cameraEnabled {
    [_lock lock]; BOOL value = _cameraEnabled; [_lock unlock]; return value;
}
- (void)setCameraEnabled:(BOOL)value {
    [_lock lock]; _cameraEnabled = value && _photo != nil; [self saveLocked]; [_lock unlock];
    [self notifyChanged];
}
- (BOOL)cameraPreviewEnabled {
    [_lock lock]; BOOL value = _cameraPreviewEnabled; [_lock unlock]; return value;
}
- (void)setCameraPreviewEnabled:(BOOL)value {
    [_lock lock]; _cameraPreviewEnabled = value && _photo != nil; [self saveLocked]; [_lock unlock];
    [self notifyChanged];
}
- (BOOL)locationEnabled {
    [_lock lock]; BOOL value = _locationEnabled; [_lock unlock]; return value;
}
- (void)setLocationEnabled:(BOOL)value {
    [_lock lock]; _locationEnabled = value; [self saveLocked]; [_lock unlock];
    [self notifyChanged];
}
- (CLLocationCoordinate2D)coordinate {
    [_lock lock]; CLLocationCoordinate2D value = _coordinate; [_lock unlock]; return value;
}
- (void)setCoordinate:(CLLocationCoordinate2D)value {
    if (!CLLocationCoordinate2DIsValid(value) || !isfinite(value.latitude) || !isfinite(value.longitude)) return;
    [_lock lock]; _coordinate = value; [self saveLocked]; [_lock unlock];
    [self notifyChanged];
}
- (MSBPhotoAsset *)selectedPhoto {
    [_lock lock]; MSBPhotoAsset *value = _photo; [_lock unlock]; return value;
}
- (MSBPhotoAsset *)replacementPhoto {
    [_lock lock]; MSBPhotoAsset *value = (_cameraEnabled || _cameraPreviewEnabled) ? _photo : nil; [_lock unlock]; return value;
}

- (NSURL *)configurationDirectoryURL {
    return [[[self photoURL] URLByDeletingLastPathComponent] URLByAppendingPathComponent:@"Configurations" isDirectory:YES];
}

- (NSURL *)configurationURLForName:(NSString *)name {
    // URL-safe Base64 keeps names (including Chinese) reversible without letting
    // a user-entered slash or ".." escape the configurations directory.
    NSString *filename = [[name dataUsingEncoding:NSUTF8StringEncoding] base64EncodedStringWithOptions:0];
    filename = [[filename stringByReplacingOccurrencesOfString:@"/" withString:@"_"]
                stringByReplacingOccurrencesOfString:@"+" withString:@"-"];
    return [[self configurationDirectoryURL] URLByAppendingPathComponent:[filename stringByAppendingPathExtension:@"plist"]];
}

- (NSArray<NSString *> *)savedConfigurationNames {
    NSArray<NSURL *> *files = [[NSFileManager defaultManager] contentsOfDirectoryAtURL:[self configurationDirectoryURL]
        includingPropertiesForKeys:nil options:NSDirectoryEnumerationSkipsHiddenFiles error:nil];
    NSMutableArray<NSString *> *names = [NSMutableArray array];
    for (NSURL *url in files) {
        if (![url.pathExtension isEqualToString:@"plist"]) continue;
        NSString *encoded = [[url.lastPathComponent.stringByDeletingPathExtension
                              stringByReplacingOccurrencesOfString:@"_" withString:@"/"]
                             stringByReplacingOccurrencesOfString:@"-" withString:@"+"];
        NSData *data = [[NSData alloc] initWithBase64EncodedString:encoded options:0];
        NSString *name = data ? [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] : nil;
        if (MSBConfigurationName(name) && [url.lastPathComponent isEqualToString:[self configurationURLForName:name].lastPathComponent]) {
            [names addObject:name];
        }
    }
    return [names sortedArrayUsingSelector:@selector(localizedStandardCompare:)];
}

- (NSString *)currentConfigurationName {
    [_lock lock]; NSString *name = _currentConfigurationName; [_lock unlock]; return name;
}

- (BOOL)renameConfigurationNamed:(NSString *)name toName:(NSString *)newName error:(NSError **)error {
    name = MSBConfigurationName(name);
    newName = MSBConfigurationName(newName);
    if (!name || !newName) return MSBSettingsError(error, @"请输入 1～40 个字符的配置名称。");
    [_lock lock];
    NSFileManager *manager = NSFileManager.defaultManager;
    NSURL *source = [self configurationURLForName:name], *destination = [self configurationURLForName:newName];
    BOOL success;
    if (![manager fileExistsAtPath:source.path]) success = MSBSettingsError(error, @"要重命名的配置已不存在。");
    else if ([name isEqualToString:newName]) success = YES;
    else if ([manager fileExistsAtPath:destination.path]) success = MSBSettingsError(error, @"该配置名称已被使用，请换一个名称。");
    else success = [manager moveItemAtURL:source toURL:destination error:error];
    if (success && [_currentConfigurationName isEqualToString:name]) {
        _currentConfigurationName = [newName copy];
        [self saveLocked];
    }
    [_lock unlock];
    if (success) [self notifyChanged];
    return success;
}

- (BOOL)deleteConfigurationNamed:(NSString *)name error:(NSError **)error {
    name = MSBConfigurationName(name);
    if (!name) return MSBSettingsError(error, @"无效的配置名称。");
    [_lock lock];
    BOOL success = [NSFileManager.defaultManager removeItemAtURL:[self configurationURLForName:name] error:error];
    if (success && [_currentConfigurationName isEqualToString:name]) {
        _currentConfigurationName = nil;
        [self saveLocked];
    }
    [_lock unlock];
    if (success) [self notifyChanged];
    return success;
}

- (BOOL)saveConfigurationNamed:(NSString *)name error:(NSError **)error {
    name = MSBConfigurationName(name);
    if (!name) return MSBSettingsError(error, @"请输入 1～40 个字符的配置名称。");
    [_lock lock];
    NSMutableDictionary *snapshot = [@{
        @"version": @1, @"camera": @(_cameraEnabled), @"cameraPreview": @(_cameraPreviewEnabled),
        @"location": @(_locationEnabled), @"latitude": @(_coordinate.latitude), @"longitude": @(_coordinate.longitude)
    } mutableCopy];
    if (_photo) snapshot[@"photo"] = _photo.JPEGData;
    NSData *data = [NSPropertyListSerialization dataWithPropertyList:snapshot format:NSPropertyListBinaryFormat_v1_0
                                                           options:0 error:error];
    BOOL success = data && [[NSFileManager defaultManager] createDirectoryAtURL:[self configurationDirectoryURL]
        withIntermediateDirectories:YES attributes:nil error:error] &&
        [data writeToURL:[self configurationURLForName:name] options:NSDataWritingAtomic error:error];
    if (success) {
        _currentConfigurationName = [name copy];
        [self saveLocked];
    }
    [_lock unlock];
    if (success) [self notifyChanged];
    return success;
}

- (BOOL)applyConfigurationNamed:(NSString *)name error:(NSError **)error {
    name = MSBConfigurationName(name);
    if (!name) return MSBSettingsError(error, @"请输入 1～40 个字符的配置名称。");
    NSData *data = [NSData dataWithContentsOfURL:[self configurationURLForName:name] options:0 error:error];
    if (!data) return NO;
    id value = [NSPropertyListSerialization propertyListWithData:data options:NSPropertyListImmutable format:nil error:error];
    if (![value isKindOfClass:NSDictionary.class]) return MSBSettingsError(error, @"配置文件无效，无法切换。");
    NSDictionary *snapshot = value;
    for (NSString *key in @[@"version", @"camera", @"cameraPreview", @"location", @"latitude", @"longitude"]) {
        if (![snapshot[key] isKindOfClass:NSNumber.class]) return MSBSettingsError(error, @"配置内容不完整，无法切换。");
    }
    CLLocationCoordinate2D coordinate = CLLocationCoordinate2DMake([snapshot[@"latitude"] doubleValue],
                                                                  [snapshot[@"longitude"] doubleValue]);
    if ([snapshot[@"version"] integerValue] != 1 || !isfinite(coordinate.latitude) || !isfinite(coordinate.longitude) ||
        !CLLocationCoordinate2DIsValid(coordinate)) return MSBSettingsError(error, @"配置版本或经纬度无效，无法切换。");
    NSData *jpeg = snapshot[@"photo"];
    if (jpeg && ![jpeg isKindOfClass:NSData.class]) return MSBSettingsError(error, @"配置中的照片无效。");
    UIImage *image = jpeg ? [UIImage imageWithData:jpeg] : nil;
    BOOL camera = [snapshot[@"camera"] boolValue], preview = [snapshot[@"cameraPreview"] boolValue];
    if ((jpeg && !image) || ((camera || preview) && !image)) return MSBSettingsError(error, @"配置中的替换照片缺失或损坏。");
    MSBPhotoAsset *asset = image ? [[MSBPhotoAsset alloc] initWithImage:image data:jpeg] : nil;
    [_lock lock];
    BOOL success = [self writePhotoDataLocked:jpeg error:error];
    if (success) {
        _photo = asset;
        _cameraEnabled = camera;
        _cameraPreviewEnabled = preview;
        _locationEnabled = [snapshot[@"location"] boolValue];
        _coordinate = coordinate;
        _currentConfigurationName = [name copy];
        [self saveLocked];
    }
    [_lock unlock];
    if (success) [self notifyChanged];
    return success;
}

// Called with the settings lock held, so importing and switching configurations
// cannot leave replacement.jpg and the in-memory photo from different changes.
- (BOOL)writePhotoDataLocked:(NSData *)data error:(NSError **)error {
    NSURL *url = [self photoURL];
    NSFileManager *manager = NSFileManager.defaultManager;
    if (!data) return ![manager fileExistsAtPath:url.path] || [manager removeItemAtURL:url error:error];
    return [manager createDirectoryAtURL:[url URLByDeletingLastPathComponent]
           withIntermediateDirectories:YES attributes:nil error:error] &&
           [data writeToURL:url options:NSDataWritingAtomic error:error];
}

- (BOOL)importPhotoData:(NSData *)data error:(NSError **)error {
    CGImageSourceRef source = CGImageSourceCreateWithData((__bridge CFDataRef)data, NULL);
    CGImageRef cgImage = source ? CGImageSourceCreateThumbnailAtIndex(source, 0, (__bridge CFDictionaryRef)@{
        (id)kCGImageSourceCreateThumbnailFromImageAlways: @YES,
        (id)kCGImageSourceCreateThumbnailWithTransform: @YES,
        (id)kCGImageSourceShouldCacheImmediately: @YES
    }) : NULL;
    NSDictionary *properties = source ? CFBridgingRelease(CGImageSourceCopyPropertiesAtIndex(source, 0, NULL)) : nil;
    if (source) CFRelease(source);
    if (!cgImage) {
        if (error) *error = [NSError errorWithDomain:@"MSBTweak" code:1 userInfo:@{
            NSLocalizedDescriptionKey: @"无法解码这张照片，请选择 JPEG、PNG 或 HEIC 图片。"
        }];
        return NO;
    }
    NSMutableData *encoded = [NSMutableData data];
    CGImageDestinationRef destination = CGImageDestinationCreateWithData((__bridge CFMutableDataRef)encoded,
        CFSTR("public.jpeg"), 1, NULL);
    BOOL encodedOK = NO;
    if (destination) {
        NSMutableDictionary *metadata = [MSBPhotoMetadataForSize(properties ?: @{}, CGImageGetWidth(cgImage),
                                                               CGImageGetHeight(cgImage)) mutableCopy];
        metadata[(id)kCGImageDestinationLossyCompressionQuality] = @0.95;
        CGImageDestinationAddImage(destination, cgImage, (__bridge CFDictionaryRef)metadata);
        encodedOK = CGImageDestinationFinalize(destination);
        CFRelease(destination);
    }
    CGImageRelease(cgImage);
    NSData *jpeg = encodedOK ? [encoded copy] : nil;
    if (!jpeg) {
        if (error) *error = [NSError errorWithDomain:@"MSBTweak" code:2 userInfo:@{
            NSLocalizedDescriptionKey: @"照片转换失败。"
        }];
        return NO;
    }
    // Use the encoded image for every API, so JPEG and pixel-buffer consumers agree.
    MSBPhotoAsset *asset = [[MSBPhotoAsset alloc] initWithImage:[UIImage imageWithData:jpeg] data:jpeg];
    [_lock lock];
    BOOL success = [self writePhotoDataLocked:jpeg error:error];
    if (success) _photo = asset;
    [_lock unlock];
    if (success) [self notifyChanged];
    return success;
}

- (CLLocation *)simulatedLocation {
    return [[CLLocation alloc] initWithCoordinate:self.coordinate altitude:0
                              horizontalAccuracy:5 verticalAccuracy:5 course:-1 speed:0
                                       timestamp:[NSDate date]];
}
@end
