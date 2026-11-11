#import "MSBTweakUI.h"
#import "MSBTweakSettings.h"
#import <PhotosUI/PhotosUI.h>
#import <MapKit/MapKit.h>

// UIAlertAction may run after UIKit has already dismissed its alert. Dismiss
// only that alert, never the settings controller (which would close the sheet).
static void MSBAfterDismissingAlert(UIAlertController *alert, dispatch_block_t completion) {
    if (!alert.presentingViewController) {
        completion();
        return;
    }
    if (alert.isBeingDismissed && alert.transitionCoordinator &&
        [alert.transitionCoordinator animateAlongsideTransition:nil completion:^(__unused id<UIViewControllerTransitionCoordinatorContext> context) {
            completion();
        }]) return;
    [alert dismissViewControllerAnimated:YES completion:completion];
}

static void MSBShowError(UIViewController *controller, NSString *message) {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"MSBTweak" message:message
                                                                          preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleDefault handler:nil]];
    [controller presentViewController:alert animated:YES completion:nil];
}

@interface MSBLocationController : UIViewController <MKMapViewDelegate, UITextFieldDelegate>
@property(nonatomic) MKMapView *map;
@property(nonatomic) UITextField *latitudeField;
@property(nonatomic) UITextField *longitudeField;
@property(nonatomic) UILabel *preview;
@property(nonatomic) CLLocationCoordinate2D selectedCoordinate;
@property(nonatomic) MKPointAnnotation *pin;
@end

@implementation MSBLocationController
- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"选择模拟位置";
    self.view.backgroundColor = UIColor.systemBackgroundColor;
    self.selectedCoordinate = MSBSettings.shared.coordinate;
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithTitle:@"保存"
        style:UIBarButtonItemStyleDone target:self action:@selector(save)];
    self.map = [MKMapView new];
    self.map.translatesAutoresizingMaskIntoConstraints = NO;
    self.map.delegate = self;
    self.map.showsUserLocation = NO;
    self.map.mapType = MKMapTypeStandard;
    [self.map addGestureRecognizer:[[UILongPressGestureRecognizer alloc] initWithTarget:self action:@selector(pickPoint:)]];
    [self.view addSubview:self.map];

    UILabel *hint = [UILabel new];
    hint.text = @"长按地图选点，或输入经纬度后点击预览。";
    hint.font = [UIFont preferredFontForTextStyle:UIFontTextStyleFootnote];
    hint.textColor = UIColor.secondaryLabelColor;
    hint.numberOfLines = 0;
    self.preview = [UILabel new];
    self.preview.font = [UIFont monospacedDigitSystemFontOfSize:13 weight:UIFontWeightRegular];
    self.preview.numberOfLines = 0;
    self.latitudeField = [self coordinateField:@"纬度（-90 ～ 90）"];
    self.longitudeField = [self coordinateField:@"经度（-180 ～ 180）"];
    UIButton *previewButton = [UIButton buttonWithType:UIButtonTypeSystem];
    [previewButton setTitle:@"预览输入的位置" forState:UIControlStateNormal];
    [previewButton addTarget:self action:@selector(previewInput) forControlEvents:UIControlEventTouchUpInside];
    UIStackView *form = [[UIStackView alloc] initWithArrangedSubviews:@[hint, self.latitudeField, self.longitudeField,
                                                                 previewButton, self.preview]];
    form.axis = UILayoutConstraintAxisVertical;
    form.spacing = 10;
    form.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:form];
    UILayoutGuide *safe = self.view.safeAreaLayoutGuide;
    NSLayoutYAxisAnchor *formBottom = safe.bottomAnchor;
    if (@available(iOS 15.0, *)) formBottom = self.view.keyboardLayoutGuide.topAnchor;
    [NSLayoutConstraint activateConstraints:@[
        [form.leadingAnchor constraintEqualToAnchor:safe.leadingAnchor constant:16],
        [form.trailingAnchor constraintEqualToAnchor:safe.trailingAnchor constant:-16],
        [form.bottomAnchor constraintEqualToAnchor:formBottom constant:-12],
        [self.map.topAnchor constraintEqualToAnchor:safe.topAnchor],
        [self.map.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [self.map.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [self.map.bottomAnchor constraintEqualToAnchor:form.topAnchor constant:-12],
        [self.latitudeField.heightAnchor constraintEqualToConstant:40],
        [self.longitudeField.heightAnchor constraintEqualToConstant:40]
    ]];
    [self updatePreview:YES];
}
- (UITextField *)coordinateField:(NSString *)placeholder {
    UITextField *field = [UITextField new];
    field.borderStyle = UITextBorderStyleRoundedRect;
    field.placeholder = placeholder;
    field.accessibilityLabel = placeholder;
    field.keyboardType = UIKeyboardTypeNumbersAndPunctuation;
    field.autocorrectionType = UITextAutocorrectionTypeNo;
    field.delegate = self;
    field.font = [UIFont preferredFontForTextStyle:UIFontTextStyleBody];
    return field;
}
- (BOOL)textFieldShouldReturn:(UITextField *)textField {
    if (textField == self.latitudeField) [self.longitudeField becomeFirstResponder];
    else [self previewInput];
    return YES;
}
- (BOOL)readInput {
    NSScanner *latitude = [NSScanner scannerWithString:self.latitudeField.text ?: @""];
    NSScanner *longitude = [NSScanner scannerWithString:self.longitudeField.text ?: @""];
    latitude.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
    longitude.locale = latitude.locale;
    double lat = 0, lon = 0;
    if (![latitude scanDouble:&lat] || !latitude.isAtEnd || ![longitude scanDouble:&lon] || !longitude.isAtEnd ||
        !isfinite(lat) || !isfinite(lon) || !CLLocationCoordinate2DIsValid(CLLocationCoordinate2DMake(lat, lon))) {
        MSBShowError(self, @"请输入有效经纬度：纬度 -90～90，经度 -180～180，小数使用英文句点。录入 WGS-84 坐标。 ");
        return NO;
    }
    self.selectedCoordinate = CLLocationCoordinate2DMake(lat, lon);
    return YES;
}
- (void)previewInput {
    if (![self readInput]) return;
    [self.view endEditing:YES];
    [self updatePreview:YES];
}
- (void)pickPoint:(UILongPressGestureRecognizer *)gesture {
    if (gesture.state != UIGestureRecognizerStateBegan) return;
    [self.view endEditing:YES];
    self.selectedCoordinate = [self.map convertPoint:[gesture locationInView:self.map] toCoordinateFromView:self.map];
    [self updatePreview:NO];
}
- (void)updatePreview:(BOOL)recenter {
    CLLocationCoordinate2D coordinate = self.selectedCoordinate;
    self.latitudeField.text = [NSString stringWithFormat:@"%.7f", coordinate.latitude];
    self.longitudeField.text = [NSString stringWithFormat:@"%.7f", coordinate.longitude];
    self.preview.text = [NSString stringWithFormat:@"WGS-84\n纬度 %.7f  经度 %.7f", coordinate.latitude, coordinate.longitude];
    if (!self.pin) { self.pin = [MKPointAnnotation new]; [self.map addAnnotation:self.pin]; }
    self.pin.coordinate = coordinate;
    self.pin.title = @"模拟定位";
    if (recenter) [self.map setRegion:MKCoordinateRegionMakeWithDistance(coordinate, 1800, 1800) animated:YES];
}
- (void)save {
    if (![self readInput]) return;
    MSBSettings.shared.coordinate = self.selectedCoordinate;
    [self.navigationController popViewControllerAnimated:YES];
}
@end

@interface MSBSettingsController () <PHPickerViewControllerDelegate>
@property(nonatomic) BOOL importing;
@property(nonatomic) id settingsObserver;
@end

@implementation MSBSettingsController
- (instancetype)init { return [super initWithStyle:UITableViewStyleInsetGrouped]; }
- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"MSBTweak 设置";
    self.tableView.backgroundColor = UIColor.systemGroupedBackgroundColor;
    self.tableView.opaque = YES;
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithTitle:@"关闭"
        style:UIBarButtonItemStyleDone target:self action:@selector(close)];
    self.tableView.rowHeight = UITableViewAutomaticDimension;
    self.tableView.estimatedRowHeight = 56;
    __weak typeof(self) weakSelf = self;
    self.settingsObserver = [[NSNotificationCenter defaultCenter] addObserverForName:MSBSettingsDidChangeNotification
        object:nil queue:NSOperationQueue.mainQueue usingBlock:^(__unused NSNotification *notification) {
            [weakSelf.tableView reloadData];
        }];
}
- (void)dealloc {
    if (self.settingsObserver) [[NSNotificationCenter defaultCenter] removeObserver:self.settingsObserver];
}
- (void)viewWillAppear:(BOOL)animated { [super viewWillAppear:animated]; [self.tableView reloadData]; }
- (void)close { if (self.onClose) self.onClose(); }
- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView { (void)tableView; return 3; }
- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    (void)tableView;
    if (section == 0) return 4;
    if (section == 1) return 2;
    return section == 2 ? (NSInteger)MSBSettings.shared.savedConfigurationNames.count + 1 : 0;
}
- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    (void)tableView;
    if (section == 0) return @"相机照片替换";
    if (section == 1) return @"模拟定位";
    return section == 2 ? @"配置管理" : nil;
}
- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
    (void)tableView;
    if (section == 0) return @"第一个开关仅替换拍照结果；第二个开关可独立开启，同时替换相机预览和拍照结果。两个开关共用下方所选照片。预览支持标准相机预览层，照片仅保存在当前 App 内。";
    if (section == 1) return @"长按地图选点或输入 WGS-84 经纬度。需要 App 已获得系统定位授权。关闭开关后恢复真实定位。";
    return section == 2 ? @"轻点名称加载配置，修改上方设置后保存即可更新当前配置。输入新名称可另存为。点击右侧编辑按钮可更新、重命名或删除，也可左滑删除。覆盖和删除前均会确认。" : nil;
}
- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    (void)tableView;
    UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:nil];
    cell.textLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleBody];
    cell.textLabel.numberOfLines = 0;
    cell.detailTextLabel.numberOfLines = 0;
    MSBSettings *settings = MSBSettings.shared;
    if (indexPath.section == 0 && indexPath.row < 2) {
        BOOL includesPreview = indexPath.row == 1;
        cell.textLabel.text = includesPreview ? @"替换拍照照片（含预览）" : @"替换拍照照片";
        UISwitch *toggle = [UISwitch new];
        toggle.on = includesPreview ? settings.cameraPreviewEnabled : settings.cameraEnabled;
        toggle.accessibilityLabel = cell.textLabel.text;
        [toggle addTarget:self action:includesPreview ? @selector(toggleCameraPreview:) : @selector(toggleCamera:)
            forControlEvents:UIControlEventValueChanged];
        cell.accessoryView = toggle;
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
    } else if (indexPath.section == 0 && indexPath.row == 2) {
        cell.textLabel.text = self.importing ? @"正在导入照片…" : @"从相册选择替换照片";
        cell.textLabel.textColor = self.importing ? UIColor.secondaryLabelColor : UIColor.systemBlueColor;
        cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    } else if (indexPath.section == 0) {
        MSBPhotoAsset *asset = settings.selectedPhoto;
        if (!asset) {
            cell.textLabel.text = @"尚未选择照片";
            cell.detailTextLabel.text = @"支持 JPEG / PNG / HEIC";
        } else {
            UIImageView *thumbnail = [[UIImageView alloc] initWithImage:asset.image];
            thumbnail.translatesAutoresizingMaskIntoConstraints = NO;
            thumbnail.contentMode = UIViewContentModeScaleAspectFit;
            thumbnail.backgroundColor = UIColor.secondarySystemBackgroundColor;
            thumbnail.layer.cornerRadius = 10;
            thumbnail.clipsToBounds = YES;
            thumbnail.accessibilityLabel = @"已选照片缩略图";
            thumbnail.isAccessibilityElement = YES;
            UILabel *dimensions = [UILabel new];
            dimensions.translatesAutoresizingMaskIntoConstraints = NO;
            dimensions.font = [UIFont preferredFontForTextStyle:UIFontTextStyleCaption1];
            dimensions.textColor = UIColor.secondaryLabelColor;
            dimensions.text = [NSString stringWithFormat:@"已选照片 · %.0f × %.0f", asset.image.size.width, asset.image.size.height];
            [cell.contentView addSubview:thumbnail];
            [cell.contentView addSubview:dimensions];
            [NSLayoutConstraint activateConstraints:@[
                [thumbnail.topAnchor constraintEqualToAnchor:cell.contentView.topAnchor constant:12],
                [thumbnail.leadingAnchor constraintEqualToAnchor:cell.contentView.leadingAnchor constant:16],
                [thumbnail.trailingAnchor constraintEqualToAnchor:cell.contentView.trailingAnchor constant:-16],
                [thumbnail.heightAnchor constraintEqualToConstant:160],
                [dimensions.topAnchor constraintEqualToAnchor:thumbnail.bottomAnchor constant:8],
                [dimensions.leadingAnchor constraintEqualToAnchor:thumbnail.leadingAnchor],
                [dimensions.trailingAnchor constraintEqualToAnchor:thumbnail.trailingAnchor],
                [dimensions.bottomAnchor constraintEqualToAnchor:cell.contentView.bottomAnchor constant:-12]
            ]];
        }
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
    } else if (indexPath.section == 1 && indexPath.row == 0) {
        cell.textLabel.text = @"模拟定位";
        UISwitch *toggle = [UISwitch new];
        toggle.on = settings.locationEnabled;
        toggle.accessibilityLabel = @"模拟定位";
        [toggle addTarget:self action:@selector(toggleLocation:) forControlEvents:UIControlEventValueChanged];
        cell.accessoryView = toggle;
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
    } else if (indexPath.section == 1) {
        cell.textLabel.text = @"选择位置 / 地图预览";
        CLLocationCoordinate2D coordinate = settings.coordinate;
        cell.detailTextLabel.text = [NSString stringWithFormat:@"纬度 %.7f\n经度 %.7f", coordinate.latitude, coordinate.longitude];
        cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    } else if (indexPath.section == 2 && indexPath.row == 0) {
        cell.textLabel.text = @"保存当前配置…";
        if (settings.currentConfigurationName) {
            cell.detailTextLabel.text = [NSString stringWithFormat:@"当前：%@ · 可覆盖保存或另存为", settings.currentConfigurationName];
        }
        cell.textLabel.textColor = UIColor.systemBlueColor;
        cell.accessibilityTraits |= UIAccessibilityTraitButton;
    } else if (indexPath.section == 2) {
        NSArray<NSString *> *names = settings.savedConfigurationNames;
        if (indexPath.row > 0 && indexPath.row - 1 < (NSInteger)names.count) {
            NSString *name = names[indexPath.row - 1];
            cell.textLabel.text = name;
            cell.detailTextLabel.text = [name isEqualToString:settings.currentConfigurationName]
                ? @"当前配置 · 修改上方设置后保存即可更新" : @"轻点加载 · 右侧按钮编辑";
            cell.accessoryType = UITableViewCellAccessoryDetailButton;
            cell.accessibilityTraits |= UIAccessibilityTraitButton;
        } else {
            cell.textLabel.text = @"配置已更新";
            cell.selectionStyle = UITableViewCellSelectionStyleNone;
        }
    }
    return cell;
}
- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    if (indexPath.section == 0 && indexPath.row == 2 && !self.importing) {
        PHPickerConfiguration *configuration = [PHPickerConfiguration new];
        configuration.selectionLimit = 1;
        configuration.filter = PHPickerFilter.imagesFilter;
        configuration.preferredAssetRepresentationMode = PHPickerConfigurationAssetRepresentationModeCompatible;
        PHPickerViewController *picker = [[PHPickerViewController alloc] initWithConfiguration:configuration];
        picker.delegate = self;
        [self presentViewController:picker animated:YES completion:nil];
    } else if (indexPath.section == 1 && indexPath.row == 1) {
        [self.navigationController pushViewController:[MSBLocationController new] animated:YES];
    } else if (indexPath.section == 2 && indexPath.row == 0) {
        [self promptForConfigurationName];
    } else if (indexPath.section == 2) {
        NSArray<NSString *> *names = MSBSettings.shared.savedConfigurationNames;
        if (indexPath.row <= 0 || indexPath.row - 1 >= (NSInteger)names.count) {
            [tableView reloadData];
            return;
        }
        NSError *error = nil;
        if (![MSBSettings.shared applyConfigurationNamed:names[indexPath.row - 1] error:&error]) {
            MSBShowError(self, error.localizedDescription ?: @"切换配置失败，请重试。");
        }
    }
}
- (NSString *)configurationNameAtIndexPath:(NSIndexPath *)indexPath {
    if (indexPath.section != 2 || indexPath.row <= 0) return nil;
    NSArray<NSString *> *names = MSBSettings.shared.savedConfigurationNames;
    return indexPath.row - 1 < (NSInteger)names.count ? names[indexPath.row - 1] : nil;
}
- (void)tableView:(UITableView *)tableView accessoryButtonTappedForRowWithIndexPath:(NSIndexPath *)indexPath {
    NSString *name = [self configurationNameAtIndexPath:indexPath];
    if (!name) return;
    UIAlertController *menu = [UIAlertController alertControllerWithTitle:name message:@"编辑已保存的配置"
        preferredStyle:UIAlertControllerStyleActionSheet];
    __weak typeof(self) weakSelf = self;
    __weak UIAlertController *weakMenu = menu;
    [menu addAction:[UIAlertAction actionWithTitle:@"加载并编辑" style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *action) {
        MSBAfterDismissingAlert(weakMenu, ^{
            MSBSettingsController *controller = weakSelf;
            if (!controller) return;
            NSError *error = nil;
            if (![MSBSettings.shared applyConfigurationNamed:name error:&error]) {
                MSBShowError(controller, error.localizedDescription ?: @"加载配置失败。");
            } else {
                [controller.tableView reloadData];
                [controller.tableView scrollToRowAtIndexPath:[NSIndexPath indexPathForRow:0 inSection:0]
                                           atScrollPosition:UITableViewScrollPositionTop animated:YES];
            }
        });
    }]];
    [menu addAction:[UIAlertAction actionWithTitle:@"用当前设置更新" style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *action) {
        MSBAfterDismissingAlert(weakMenu, ^{ [weakSelf saveConfigurationNamed:name overwriteConfirmed:NO]; });
    }]];
    [menu addAction:[UIAlertAction actionWithTitle:@"重命名" style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *action) {
        MSBAfterDismissingAlert(weakMenu, ^{ [weakSelf promptToRenameConfiguration:name]; });
    }]];
    [menu addAction:[UIAlertAction actionWithTitle:@"删除配置" style:UIAlertActionStyleDestructive handler:^(__unused UIAlertAction *action) {
        MSBAfterDismissingAlert(weakMenu, ^{ [weakSelf confirmDeleteConfiguration:name]; });
    }]];
    [menu addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    UIPopoverPresentationController *popover = menu.popoverPresentationController;
    popover.sourceView = tableView;
    popover.sourceRect = [tableView rectForRowAtIndexPath:indexPath];
    [self presentViewController:menu animated:YES completion:nil];
}
- (UISwipeActionsConfiguration *)tableView:(UITableView *)tableView trailingSwipeActionsConfigurationForRowAtIndexPath:(NSIndexPath *)indexPath {
    (void)tableView;
    NSString *name = [self configurationNameAtIndexPath:indexPath];
    if (!name) return nil;
    __weak typeof(self) weakSelf = self;
    UIContextualAction *remove = [UIContextualAction contextualActionWithStyle:UIContextualActionStyleDestructive title:@"删除"
        handler:^(__unused UIContextualAction *action, __unused UIView *view, void (^completion)(BOOL)) {
            completion(YES);
            [weakSelf confirmDeleteConfiguration:name];
        }];
    UISwipeActionsConfiguration *configuration = [UISwipeActionsConfiguration configurationWithActions:@[remove]];
    configuration.performsFirstActionWithFullSwipe = NO;
    return configuration;
}
- (void)promptToRenameConfiguration:(NSString *)name {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"重命名配置" message:@"请输入新的配置名称（最多 40 个字符）。"
        preferredStyle:UIAlertControllerStyleAlert];
    [alert addTextFieldWithConfigurationHandler:^(UITextField *field) {
        field.text = name;
        field.placeholder = @"配置名称";
        field.accessibilityLabel = @"新配置名称";
        field.autocorrectionType = UITextAutocorrectionTypeNo;
    }];
    [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    __weak typeof(self) weakSelf = self;
    __weak UIAlertController *weakAlert = alert;
    [alert addAction:[UIAlertAction actionWithTitle:@"保存" style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *action) {
        NSString *newName = weakAlert.textFields.firstObject.text ?: @"";
        MSBAfterDismissingAlert(weakAlert, ^{
            MSBSettingsController *controller = weakSelf;
            if (!controller) return;
            NSError *error = nil;
            if (![MSBSettings.shared renameConfigurationNamed:name toName:newName error:&error]) {
                MSBShowError(controller, error.localizedDescription ?: @"重命名配置失败。");
            }
        });
    }]];
    [self presentViewController:alert animated:YES completion:nil];
}
- (void)confirmDeleteConfiguration:(NSString *)name {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"删除配置？"
        message:[NSString stringWithFormat:@"确定删除“%@”？当前已加载的照片和开关将继续生效。", name]
        preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    __weak typeof(self) weakSelf = self;
    __weak UIAlertController *weakAlert = alert;
    [alert addAction:[UIAlertAction actionWithTitle:@"删除" style:UIAlertActionStyleDestructive handler:^(__unused UIAlertAction *action) {
        MSBAfterDismissingAlert(weakAlert, ^{
            MSBSettingsController *controller = weakSelf;
            if (!controller) return;
            NSError *error = nil;
            if (![MSBSettings.shared deleteConfigurationNamed:name error:&error]) {
                MSBShowError(controller, error.localizedDescription ?: @"删除配置失败。");
            }
        });
    }]];
    [self presentViewController:alert animated:YES completion:nil];
}
- (void)promptForConfigurationName {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"保存当前配置"
        message:@"请输入配置名称（最多 40 个字符）。" preferredStyle:UIAlertControllerStyleAlert];
    [alert addTextFieldWithConfigurationHandler:^(UITextField *field) {
        field.placeholder = @"配置名称";
        field.text = MSBSettings.shared.currentConfigurationName;
        field.accessibilityLabel = @"配置名称";
        field.autocorrectionType = UITextAutocorrectionTypeNo;
        field.autocapitalizationType = UITextAutocapitalizationTypeNone;
    }];
    [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    __weak typeof(self) weakSelf = self;
    __weak UIAlertController *weakAlert = alert;
    [alert addAction:[UIAlertAction actionWithTitle:@"保存" style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *action) {
        NSString *name = [(weakAlert.textFields.firstObject.text ?: @"")
            stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
        MSBAfterDismissingAlert(weakAlert, ^{
            [weakSelf saveConfigurationNamed:name overwriteConfirmed:NO];
        });
    }]];
    [self presentViewController:alert animated:YES completion:nil];
}
- (void)saveConfigurationNamed:(NSString *)name overwriteConfirmed:(BOOL)overwriteConfirmed {
    if (name.length == 0 || name.length > 40) {
        MSBShowError(self, @"配置名称不能为空，且最多为 40 个字符。部分表情符号会占用多个字符。");
        return;
    }
    if (!overwriteConfirmed && [MSBSettings.shared.savedConfigurationNames containsObject:name]) {
        UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"覆盖已有配置？"
            message:[NSString stringWithFormat:@"已存在名为“%@”的配置。是否用当前设置覆盖？", name]
            preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
        __weak typeof(self) weakSelf = self;
        __weak UIAlertController *weakAlert = alert;
        [alert addAction:[UIAlertAction actionWithTitle:@"覆盖" style:UIAlertActionStyleDestructive handler:^(__unused UIAlertAction *action) {
            MSBAfterDismissingAlert(weakAlert, ^{
                [weakSelf saveConfigurationNamed:name overwriteConfirmed:YES];
            });
        }]];
        [self presentViewController:alert animated:YES completion:nil];
        return;
    }
    NSError *error = nil;
    if (![MSBSettings.shared saveConfigurationNamed:name error:&error]) {
        MSBShowError(self, error.localizedDescription ?: @"保存配置失败，请重试。");
    }
}
- (void)toggleCamera:(UISwitch *)sender {
    if (sender.isOn && !MSBSettings.shared.selectedPhoto) {
        sender.on = NO;
        MSBShowError(self, @"请先选择一张替换照片。");
        return;
    }
    MSBSettings.shared.cameraEnabled = sender.isOn;
}
- (void)toggleCameraPreview:(UISwitch *)sender {
    if (sender.isOn && !MSBSettings.shared.selectedPhoto) {
        sender.on = NO;
        MSBShowError(self, @"请先选择一张替换照片。");
        return;
    }
    MSBSettings.shared.cameraPreviewEnabled = sender.isOn;
}
- (void)toggleLocation:(UISwitch *)sender { MSBSettings.shared.locationEnabled = sender.isOn; }
- (void)picker:(PHPickerViewController *)picker didFinishPicking:(NSArray<PHPickerResult *> *)results {
    [picker dismissViewControllerAnimated:YES completion:^{
        NSItemProvider *provider = results.firstObject.itemProvider;
        if (!provider) return;
        self.importing = YES;
        [self.tableView reloadData];
        __weak typeof(self) weakSelf = self;
        [provider loadDataRepresentationForTypeIdentifier:@"public.image" completionHandler:^(NSData *data, NSError *loadError) {
            NSError *error = loadError;
            BOOL success = data && [MSBSettings.shared importPhotoData:data error:&error];
            dispatch_async(dispatch_get_main_queue(), ^{
                MSBSettingsController *controller = weakSelf;
                if (!controller) return;
                controller.importing = NO;
                [controller.tableView reloadData];
                if (!success && controller.view.window) MSBShowError(controller, error.localizedDescription ?: @"读取照片失败，请重试。");
            });
        }];
    }];
}
@end
