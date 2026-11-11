#import <UIKit/UIKit.h>
#import <CoreLocation/CoreLocation.h>

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT NSNotificationName const MSBSettingsDidChangeNotification;
FOUNDATION_EXPORT NSDictionary *MSBPhotoMetadataForSize(NSDictionary *metadata, size_t width, size_t height);

@interface MSBPhotoAsset : NSObject
@property(nonatomic, readonly) UIImage *image;
@property(nonatomic, readonly) NSData *JPEGData;
@property(nonatomic, readonly) NSDictionary *metadata;
- (instancetype)initWithImage:(UIImage *)image data:(NSData *)data;
@end

@interface MSBSettings : NSObject
+ (instancetype)shared;
@property(nonatomic) BOOL cameraEnabled;
@property(nonatomic) BOOL cameraPreviewEnabled;
@property(nonatomic) BOOL locationEnabled;
@property(nonatomic) CLLocationCoordinate2D coordinate;
@property(nonatomic, readonly, nullable) MSBPhotoAsset *selectedPhoto;
@property(nonatomic, readonly, nullable) MSBPhotoAsset *replacementPhoto;
@property(nonatomic, readonly) NSArray<NSString *> *savedConfigurationNames;
@property(nonatomic, readonly, nullable) NSString *currentConfigurationName;
- (BOOL)renameConfigurationNamed:(NSString *)name toName:(NSString *)newName error:(NSError * _Nullable * _Nullable)error;
- (BOOL)deleteConfigurationNamed:(NSString *)name error:(NSError * _Nullable * _Nullable)error;
- (BOOL)saveConfigurationNamed:(NSString *)name error:(NSError * _Nullable * _Nullable)error;
- (BOOL)applyConfigurationNamed:(NSString *)name error:(NSError * _Nullable * _Nullable)error;
- (BOOL)importPhotoData:(NSData *)data error:(NSError **)error;
- (CLLocation *)simulatedLocation;
@end

NS_ASSUME_NONNULL_END
