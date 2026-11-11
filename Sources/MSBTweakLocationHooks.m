#import "MSBTweakHooks.h"
#import "MSBTweakSettings.h"
#import <CoreLocation/CoreLocation.h>
#import <objc/runtime.h>

static char MSBLocationStateKey;
static NSHashTable *MSBLocationStates;

@interface CLLocationManager (MSBOriginalRequest)
- (void)msb_requestLocation;
@end

@interface MSBLocationDelegate : NSObject <CLLocationManagerDelegate>
@property(nonatomic, weak) id<CLLocationManagerDelegate> target;
@end

@interface MSBLocationState : NSObject
@property(nonatomic, weak) CLLocationManager *manager;
@property(nonatomic, strong) MSBLocationDelegate *proxy;
@property(nonatomic) BOOL updating;
@property(nonatomic) BOOL pendingRequest;
@property(nonatomic) NSUInteger generation;
- (instancetype)initWithManager:(CLLocationManager *)manager;
- (void)enqueueLocation;
- (void)enqueueLocationForRequest:(BOOL)request;
@end

static BOOL MSBCanSimulate(CLLocationManager *manager) {
    CLAuthorizationStatus status = manager.authorizationStatus;
    return MSBSettings.shared.locationEnabled &&
        (status == kCLAuthorizationStatusAuthorizedAlways || status == kCLAuthorizationStatusAuthorizedWhenInUse);
}

@implementation MSBLocationState {
    CFRunLoopRef _callbackRunLoop;
}
- (instancetype)initWithManager:(CLLocationManager *)manager {
    if ((self = [super init])) {
        _manager = manager;
        _proxy = [MSBLocationDelegate new];
        _callbackRunLoop = CFRunLoopGetCurrent();
        CFRetain(_callbackRunLoop);
    }
    return self;
}
- (void)dealloc { CFRelease(_callbackRunLoop); }
- (void)enqueueLocation { [self enqueueLocationForRequest:NO]; }
- (void)enqueueLocationForRequest:(BOOL)request {
    NSUInteger generation;
    @synchronized (self) { generation = self.generation; }
    __weak typeof(self) weakSelf = self;
    CFRunLoopPerformBlock(_callbackRunLoop, kCFRunLoopCommonModes, ^{
        MSBLocationState *state = weakSelf;
        if (!state) return;
        @synchronized (state) {
            if (generation != state.generation || (request && !state.pendingRequest)) return;
            if (request) state.pendingRequest = NO;
        }
        CLLocationManager *manager = state.manager;
        if (!manager) return;
        if (!MSBCanSimulate(manager)) {
            // A one-shot request must still finish if simulation was switched off while queued.
            if (request) [manager msb_requestLocation];
            return;
        }
        id<CLLocationManagerDelegate> target = state.proxy.target;
        CLLocation *location = MSBSettings.shared.simulatedLocation;
        if ([target respondsToSelector:@selector(locationManager:didUpdateLocations:)]) {
            [target locationManager:manager didUpdateLocations:@[location]];
        } else if ([target respondsToSelector:@selector(locationManager:didUpdateToLocation:fromLocation:)]) {
            [target locationManager:manager didUpdateToLocation:location fromLocation:location];
        }
    });
    CFRunLoopWakeUp(_callbackRunLoop);
}
@end

static MSBLocationState *MSBState(CLLocationManager *manager) {
    @synchronized (manager) {
        MSBLocationState *state = objc_getAssociatedObject(manager, &MSBLocationStateKey);
        if (!state) {
            state = [[MSBLocationState alloc] initWithManager:manager];
            objc_setAssociatedObject(manager, &MSBLocationStateKey, state, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            @synchronized (MSBLocationStates) { [MSBLocationStates addObject:state]; }
        }
        return state;
    }
}

@implementation MSBLocationDelegate
- (BOOL)respondsToSelector:(SEL)selector {
    return [super respondsToSelector:selector] || [self.target respondsToSelector:selector];
}
- (id)forwardingTargetForSelector:(SEL)selector {
    return [self.target respondsToSelector:selector] ? self.target : [super forwardingTargetForSelector:selector];
}
- (NSMethodSignature *)methodSignatureForSelector:(SEL)selector {
    NSMethodSignature *signature = [(NSObject *)self.target methodSignatureForSelector:selector];
    if (signature) return signature;
    struct objc_method_description description = protocol_getMethodDescription(@protocol(CLLocationManagerDelegate), selector, NO, YES);
    if (!description.types) description = protocol_getMethodDescription(@protocol(CLLocationManagerDelegate), selector, YES, YES);
    return description.types ? [NSMethodSignature signatureWithObjCTypes:description.types] : [super methodSignatureForSelector:selector];
}
- (void)forwardInvocation:(NSInvocation *)invocation {
    id target = self.target;
    if ([target respondsToSelector:invocation.selector]) [invocation invokeWithTarget:target];
    else if (invocation.methodSignature.methodReturnLength) {
        NSMutableData *zero = [NSMutableData dataWithLength:invocation.methodSignature.methodReturnLength];
        [invocation setReturnValue:zero.mutableBytes];
    }
}
- (void)locationManager:(CLLocationManager *)manager didUpdateLocations:(NSArray<CLLocation *> *)locations {
    id<CLLocationManagerDelegate> target = self.target;
    NSArray *result = MSBCanSimulate(manager) ? @[MSBSettings.shared.simulatedLocation] : locations;
    if ([target respondsToSelector:_cmd]) {
        [target locationManager:manager didUpdateLocations:result];
    } else if (result.count && [target respondsToSelector:@selector(locationManager:didUpdateToLocation:fromLocation:)]) {
        [target locationManager:manager didUpdateToLocation:result.lastObject fromLocation:result.firstObject];
    }
}
- (void)locationManager:(CLLocationManager *)manager didUpdateToLocation:(CLLocation *)newLocation
          fromLocation:(CLLocation *)oldLocation {
    id<CLLocationManagerDelegate> target = self.target;
    CLLocation *replacement = MSBCanSimulate(manager) ? MSBSettings.shared.simulatedLocation : nil;
    if ([target respondsToSelector:_cmd]) {
        [target locationManager:manager didUpdateToLocation:replacement ?: newLocation fromLocation:replacement ?: oldLocation];
    } else if ([target respondsToSelector:@selector(locationManager:didUpdateLocations:)]) {
        [target locationManager:manager didUpdateLocations:@[replacement ?: newLocation]];
    }
}
- (void)locationManager:(CLLocationManager *)manager didFailWithError:(NSError *)error {
    // Preserve permission and unrelated errors; replace only transient positioning failures.
    if (MSBCanSimulate(manager) && [error.domain isEqualToString:kCLErrorDomain] && error.code == kCLErrorLocationUnknown) {
        [MSBState(manager) enqueueLocation];
    } else if ([self.target respondsToSelector:_cmd]) {
        [self.target locationManager:manager didFailWithError:error];
    }
}
- (void)locationManagerDidChangeAuthorization:(CLLocationManager *)manager {
    id<CLLocationManagerDelegate> target = self.target;
    if ([target respondsToSelector:_cmd]) {
        [target locationManagerDidChangeAuthorization:manager];
    } else if ([target respondsToSelector:@selector(locationManager:didChangeAuthorizationStatus:)]) {
        [target locationManager:manager didChangeAuthorizationStatus:manager.authorizationStatus];
    }
    MSBLocationState *state = MSBState(manager);
    @synchronized (state) { if (!state.updating) return; }
    if (MSBCanSimulate(manager)) [state enqueueLocation];
}
- (void)locationManager:(CLLocationManager *)manager didChangeAuthorizationStatus:(CLAuthorizationStatus)status {
    if ([self.target respondsToSelector:_cmd]) [self.target locationManager:manager didChangeAuthorizationStatus:status];
}
@end

@interface CLLocationManager (MSBTweak)
- (instancetype)msb_init;
- (void)msb_setDelegate:(id<CLLocationManagerDelegate>)delegate;
- (id<CLLocationManagerDelegate>)msb_delegate;
- (void)msb_startUpdatingLocation;
- (void)msb_stopUpdatingLocation;
- (void)msb_requestLocation;
- (CLLocation *)msb_location;
@end

@implementation CLLocationManager (MSBTweak)
- (instancetype)msb_init {
    CLLocationManager *manager = [self msb_init];
    if (manager) MSBState(manager);
    return manager;
}
- (void)msb_setDelegate:(id<CLLocationManagerDelegate>)delegate {
    MSBLocationState *state = MSBState(self);
    if (delegate == (id)state.proxy) {
        [self msb_setDelegate:delegate];
        return;
    }
    state.proxy.target = delegate;
    [self msb_setDelegate:delegate ? state.proxy : nil];
}
- (id<CLLocationManagerDelegate>)msb_delegate {
    MSBLocationState *state = objc_getAssociatedObject(self, &MSBLocationStateKey);
    return state ? state.proxy.target : [self msb_delegate];
}
- (void)msb_startUpdatingLocation {
    MSBLocationState *state = MSBState(self);
    @synchronized (state) { state.updating = YES; state.pendingRequest = NO; state.generation++; }
    [self msb_startUpdatingLocation];
    if (MSBCanSimulate(self)) [state enqueueLocation];
}
- (void)msb_stopUpdatingLocation {
    MSBLocationState *state = MSBState(self);
    @synchronized (state) { state.updating = NO; state.pendingRequest = NO; state.generation++; }
    [self msb_stopUpdatingLocation];
}
- (void)msb_requestLocation {
    if (!MSBCanSimulate(self)) { [self msb_requestLocation]; return; }
    MSBLocationState *state = MSBState(self);
    @synchronized (state) {
        if (state.updating || state.pendingRequest) return;
        state.pendingRequest = YES;
    }
    [state enqueueLocationForRequest:YES];
}
- (CLLocation *)msb_location {
    return MSBCanSimulate(self) ? MSBSettings.shared.simulatedLocation : [self msb_location];
}
@end

static void MSBPublishLocations(void) {
    NSArray *states;
    @synchronized (MSBLocationStates) { states = MSBLocationStates.allObjects; }
    for (MSBLocationState *state in states) {
        BOOL updating;
        @synchronized (state) { updating = state.updating; }
        if (updating && state.manager && MSBCanSimulate(state.manager)) [state enqueueLocation];
    }
}

void MSBInstallLocationHooks(void) {
    MSBLocationStates = [NSHashTable weakObjectsHashTable];
    MSBSwizzle(CLLocationManager.class, @selector(init), @selector(msb_init));
    MSBSwizzle(CLLocationManager.class, @selector(setDelegate:), @selector(msb_setDelegate:));
    MSBSwizzle(CLLocationManager.class, @selector(delegate), @selector(msb_delegate));
    MSBSwizzle(CLLocationManager.class, @selector(startUpdatingLocation), @selector(msb_startUpdatingLocation));
    MSBSwizzle(CLLocationManager.class, @selector(stopUpdatingLocation), @selector(msb_stopUpdatingLocation));
    MSBSwizzle(CLLocationManager.class, @selector(requestLocation), @selector(msb_requestLocation));
    MSBSwizzle(CLLocationManager.class, @selector(location), @selector(msb_location));
    dispatch_async(dispatch_get_main_queue(), ^{
        NSTimer *timer = [NSTimer timerWithTimeInterval:1 repeats:YES block:^(__unused NSTimer *timer) {
            MSBPublishLocations();
        }];
        [[NSRunLoop mainRunLoop] addTimer:timer forMode:NSRunLoopCommonModes];
        [[NSNotificationCenter defaultCenter] addObserverForName:MSBSettingsDidChangeNotification object:nil
            queue:NSOperationQueue.mainQueue usingBlock:^(__unused NSNotification *notification) {
                MSBPublishLocations();
            }];
    });
}
