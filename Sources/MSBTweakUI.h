#import <UIKit/UIKit.h>

@interface MSBSettingsController : UITableViewController
@property(nonatomic, copy) void (^onClose)(void);
@end

@interface MSBOverlayCoordinator : NSObject
+ (instancetype)shared;
- (void)start;
@end
