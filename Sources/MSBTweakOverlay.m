#import "MSBTweakUI.h"
#import "MSBTweakSettings.h"

static NSString *const MSBPositionKey = @"MSBTweak.FloatingPosition.v1";

@interface MSBOverlayWindow : UIWindow
@end
@implementation MSBOverlayWindow
- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    UIView *hit = [super hitTest:point withEvent:event];
    if (hit == self || hit == self.rootViewController.view) return nil;
    return hit;
}
@end

@interface MSBOverlayRoot : UIViewController <UIAdaptivePresentationControllerDelegate>
@property(nonatomic) UIButton *button;
@property(nonatomic, weak) UIWindow *previousKeyWindow;
@property(nonatomic, weak) UIWindow *hostWindow;
@property(nonatomic) BOOL dragging;
@property(nonatomic) CGPoint dragStart;
@property(nonatomic) CGFloat relativeY;
@property(nonatomic) BOOL rightEdge;
@end

@implementation MSBOverlayRoot
- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = UIColor.clearColor;
    NSDictionary *position = [[NSUserDefaults standardUserDefaults] dictionaryForKey:MSBPositionKey];
    self.relativeY = position ? [position[@"y"] doubleValue] : 0.35;
    if (!isfinite(self.relativeY)) self.relativeY = 0.35;
    self.relativeY = MAX(0, MIN(1, self.relativeY));
    self.rightEdge = position ? [position[@"right"] boolValue] : YES;
    self.button = [UIButton buttonWithType:UIButtonTypeCustom];
    self.button.frame = CGRectMake(0, 0, 44, 44);
    self.button.backgroundColor = [UIColor colorWithWhite:0.12 alpha:0.86];
    self.button.tintColor = UIColor.whiteColor;
    self.button.layer.cornerRadius = 22;
    self.button.layer.borderWidth = 1;
    self.button.layer.borderColor = [UIColor colorWithWhite:1 alpha:0.4].CGColor;
    self.button.layer.shadowColor = UIColor.blackColor.CGColor;
    self.button.layer.shadowOpacity = 0.2;
    self.button.layer.shadowRadius = 4;
    self.button.layer.shadowOffset = CGSizeMake(0, 2);
    [self.button setImage:[UIImage systemImageNamed:@"camera.fill"] forState:UIControlStateNormal];
    self.button.accessibilityLabel = @"MSBTweak 设置";
    self.button.accessibilityHint = @"轻点打开照片替换与模拟定位设置，可拖动调整位置";
    [self.button addTarget:self action:@selector(openSettings) forControlEvents:UIControlEventTouchUpInside];
    [self.button addGestureRecognizer:[[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(drag:)]];
    [self.view addSubview:self.button];
}
- (UIInterfaceOrientationMask)supportedInterfaceOrientations {
    UIInterfaceOrientationMask mask = self.hostWindow.rootViewController.supportedInterfaceOrientations;
    return mask ?: UIInterfaceOrientationMaskAll;
}
- (BOOL)shouldAutorotate { return YES; }
- (CGRect)movementBounds {
    CGRect bounds = UIEdgeInsetsInsetRect(self.view.bounds, self.view.safeAreaInsets);
    bounds = CGRectInset(bounds, 6 + 22, 6 + 22);
    if (bounds.size.width < 0) bounds.size.width = 0;
    if (bounds.size.height < 0) bounds.size.height = 0;
    return bounds;
}
- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    if (!self.dragging) {
        CGRect bounds = [self movementBounds];
        self.button.center = CGPointMake(self.rightEdge ? CGRectGetMaxX(bounds) : CGRectGetMinX(bounds),
                                         CGRectGetMinY(bounds) + bounds.size.height * self.relativeY);
    }
}
- (void)drag:(UIPanGestureRecognizer *)gesture {
    if (gesture.state == UIGestureRecognizerStateBegan) {
        self.dragging = YES;
        self.dragStart = self.button.center;
    }
    CGPoint translation = [gesture translationInView:self.view];
    CGRect bounds = [self movementBounds];
    CGPoint point = CGPointMake(MAX(CGRectGetMinX(bounds), MIN(CGRectGetMaxX(bounds), self.dragStart.x + translation.x)),
                               MAX(CGRectGetMinY(bounds), MIN(CGRectGetMaxY(bounds), self.dragStart.y + translation.y)));
    self.button.center = point;
    if (gesture.state == UIGestureRecognizerStateEnded || gesture.state == UIGestureRecognizerStateCancelled) {
        self.dragging = NO;
        self.rightEdge = point.x >= CGRectGetMidX(self.view.bounds);
        self.relativeY = bounds.size.height > 0 ? (point.y - CGRectGetMinY(bounds)) / bounds.size.height : 0.5;
        [[NSUserDefaults standardUserDefaults] setObject:@{@"right": @(self.rightEdge), @"y": @(self.relativeY)} forKey:MSBPositionKey];
        [UIView animateWithDuration:0.2 animations:^{
            self.button.center = CGPointMake(self.rightEdge ? CGRectGetMaxX(bounds) : CGRectGetMinX(bounds), point.y);
        }];
    }
}
- (UIWindow *)currentHostKeyWindow {
    NSArray<UIWindow *> *windows = self.view.window.windowScene ? self.view.window.windowScene.windows : UIApplication.sharedApplication.windows;
    for (UIWindow *window in windows) if (window != self.view.window && window.isKeyWindow) return window;
    return self.hostWindow;
}
- (void)openSettings {
    if (self.presentedViewController) return;
    self.previousKeyWindow = [self currentHostKeyWindow];
    [self.view.window makeKeyWindow];
    MSBSettingsController *settings = [MSBSettingsController new];
    __weak typeof(self) weakSelf = self;
    settings.onClose = ^{
        [weakSelf dismissViewControllerAnimated:YES completion:^{ [weakSelf restoreHostWindow]; }];
    };
    UINavigationController *navigation = [[UINavigationController alloc] initWithRootViewController:settings];
    navigation.view.backgroundColor = UIColor.systemGroupedBackgroundColor;
    UINavigationBarAppearance *appearance = [UINavigationBarAppearance new];
    [appearance configureWithOpaqueBackground];
    appearance.backgroundColor = UIColor.systemGroupedBackgroundColor;
    navigation.navigationBar.standardAppearance = appearance;
    navigation.navigationBar.compactAppearance = appearance;
    navigation.navigationBar.scrollEdgeAppearance = appearance;
    navigation.navigationBar.translucent = NO;
    navigation.modalPresentationStyle = UIModalPresentationPageSheet;
    if (@available(iOS 15.0, *)) {
        navigation.sheetPresentationController.detents = @[UISheetPresentationControllerDetent.largeDetent];
        navigation.sheetPresentationController.prefersGrabberVisible = YES;
    }
    [self presentViewController:navigation animated:YES completion:nil];
    navigation.presentationController.delegate = self;
}
- (void)restoreHostWindow {
    if (self.view.window.isKeyWindow && !self.previousKeyWindow.hidden) [self.previousKeyWindow makeKeyWindow];
    self.previousKeyWindow = nil;
}
- (void)presentationControllerDidDismiss:(UIPresentationController *)presentationController {
    (void)presentationController;
    [self restoreHostWindow];
}
@end

@implementation MSBOverlayCoordinator {
    NSMutableDictionary<NSString *, MSBOverlayWindow *> *_windows;
    MSBOverlayWindow *_legacyWindow;
}
+ (instancetype)shared {
    static MSBOverlayCoordinator *instance;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{ instance = [self new]; });
    return instance;
}
- (UIWindow *)hostWindowForScene:(UIWindowScene *)scene {
    NSArray<UIWindow *> *windows = scene ? scene.windows : UIApplication.sharedApplication.windows;
    for (UIWindow *window in windows) {
        if (![window isKindOfClass:MSBOverlayWindow.class] && !window.hidden && window.windowLevel == UIWindowLevelNormal && window.rootViewController) {
            if (window.isKeyWindow) return window;
        }
    }
    for (UIWindow *window in windows) {
        if (![window isKindOfClass:MSBOverlayWindow.class] && !window.hidden && window.rootViewController) return window;
    }
    return nil;
}
- (MSBOverlayWindow *)newWindowForScene:(UIWindowScene *)scene host:(UIWindow *)host {
    MSBOverlayWindow *window = scene ? [[MSBOverlayWindow alloc] initWithWindowScene:scene]
                                    : [[MSBOverlayWindow alloc] initWithFrame:UIScreen.mainScreen.bounds];
    window.backgroundColor = UIColor.clearColor;
    window.windowLevel = UIWindowLevelNormal + 1;
    MSBOverlayRoot *root = [MSBOverlayRoot new];
    root.hostWindow = host;
    window.rootViewController = root;
    // Showing a non-key window leaves the host's keyboard and responder chain alone.
    window.hidden = NO;
    return window;
}
- (void)refresh {
    UIApplication *app = UIApplication.sharedApplication;
    BOOL hasWindowScene = NO;
    for (UIScene *scene in app.connectedScenes) {
        if (![scene isKindOfClass:UIWindowScene.class]) continue;
        UIWindowScene *windowScene = (UIWindowScene *)scene;
        if (windowScene.session.role != UIWindowSceneSessionRoleApplication &&
            ![windowScene.session.role isEqualToString:UIWindowSceneSessionRoleApplication]) continue;
        hasWindowScene = YES;
        if (scene.activationState != UISceneActivationStateForegroundActive && scene.activationState != UISceneActivationStateForegroundInactive) continue;
        NSString *key = scene.session.persistentIdentifier;
        UIWindow *host = [self hostWindowForScene:windowScene];
        if (!_windows[key] && host) _windows[key] = [self newWindowForScene:windowScene host:host];
        else if (host) ((MSBOverlayRoot *)_windows[key].rootViewController).hostWindow = host;
    }
    if (!hasWindowScene && !_legacyWindow) {
        UIWindow *host = [self hostWindowForScene:nil];
        if (host) _legacyWindow = [self newWindowForScene:nil host:host];
    }
}
- (void)sceneDisconnected:(NSNotification *)notification {
    UIScene *scene = notification.object;
    NSString *key = scene.session.persistentIdentifier;
    _windows[key].hidden = YES;
    [_windows removeObjectForKey:key];
}
- (void)refreshNotification:(NSNotification *)notification {
    (void)notification;
    // Run after the host finishes handling its lifecycle notification.
    dispatch_async(dispatch_get_main_queue(), ^{ [self refresh]; });
}
- (void)start {
    if (_windows) return;
    _windows = [NSMutableDictionary dictionary];
    NSNotificationCenter *center = NSNotificationCenter.defaultCenter;
    for (NSNotificationName name in @[UIApplicationDidFinishLaunchingNotification, UIApplicationDidBecomeActiveNotification,
                                     UISceneDidActivateNotification, UIWindowDidBecomeVisibleNotification]) {
        [center addObserver:self selector:@selector(refreshNotification:) name:name object:nil];
    }
    [center addObserver:self selector:@selector(sceneDisconnected:) name:UISceneDidDisconnectNotification object:nil];
    [self refresh];
}
@end
