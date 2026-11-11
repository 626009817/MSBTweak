# MSBTweak

用于注入 iOS App 的 Objective-C 动态库，提供自定义相机照片替换、Core Location 模拟定位和可拖动悬浮设置入口。无需 MobileSubstrate、libhooker、Theos 或单独安装设置 App。

## 免责声明

本项目仅供学习、研究，以及在自有设备上对自有或已获授权的 App 做功能测试。使用者须自行遵守所在地法律法规和目标 App 的服务条款，并自行承担注入、替换照片或模拟定位带来的全部后果，包括账号限制、功能异常、数据丢失，以及因此产生的纠纷或损失。

本项目按原样提供，作者不对其适用性、稳定性、安全性或与特定 App 的兼容性作任何保证，也不对因使用、无法使用或误用本项目造成的任何直接或间接损失承担责任。

## 变更说明

### 首次提交

当前版本作为本项目的首次提交，包含以下功能：

- 注入式设置悬浮入口，以及照片替换、相机预览替换和模拟定位。
- 命名配置的保存、切换、更新、重命名与删除。
- 照片 EXIF 等元数据保留、预览刷新和拍摄过程中的图片快照处理。
- 不依赖外部 Hook 框架的实现、构建脚本、模拟器测试宿主及 GitHub Actions 构建验证。

后续版本的功能与修正将在此处追加记录。

## 产物与环境

- 真机产物：`build/iphoneos/MSBTweak.dylib`，通用二进制，包含 `arm64` 与 `arm64e`。
- 最低系统：iOS 14.0。TrollFools、TrollStore 是否支持设备和系统版本，以工具自身支持范围为准。
- 构建环境：macOS、Xcode 与 iPhoneOS SDK。只依赖系统框架。
- 模拟器产物：`build/iphonesimulator/MSBTweak.dylib`，仅用于测试，不能注入真机 App。

```sh
make
make verify
```

也可只构建普通 arm64：

```sh
make BUILD_DIR=build/iphoneos-arm64 ARCHS=arm64
```

构建会执行 ad-hoc 签名。最终 App 签名与注入处理由 TrollFools 完成；本项目不需要给动态库增加 entitlements。

推送到 `main`、打开 Pull Request，或在 GitHub Actions 中手动运行 **Build** 时，会执行 `make verify` 与 `make -C Tests`。通过后，真机动态库以名为 `MSBTweak-iphoneos` 的构建产物上传。模拟器测试宿主只在检查中编译，不随产物发布。

## 通过 TrollFools 安装

1. 把 `build/iphoneos/MSBTweak.dylib` 传到 iPhone 的“文件”App。
2. 在 TrollFools 中找到目标 App，使用注入/添加动态库功能选择该文件。不同工具版本的按钮名称可能不同。
3. 完全退出目标 App 后重新打开。
4. App 内会出现 **44 × 44 pt** 的圆形相机图标，可拖动并自动吸附到左右边缘；位置会记住。
5. 点击图标进入设置。设置页是不透明的分组列表，以页面表单打开；关闭按钮或下滑可返回 App。

更新动态库时，在 TrollFools 中替换旧注入项，再结束并重新启动目标 App。避免重复注入多份本库。卸载时用 TrollFools 移除对应注入项并重启 App。

## 使用

### 照片替换

1. 点击“从相册选择替换照片”，通过系统照片选择器选择一张照片。
2. 页面显示已选照片缩略图和像素尺寸。
3. 按需要开启相机开关：
   - **替换拍照照片**：后续通过支持的拍照接口取得的结果使用该图片，实时取景保持真实相机画面。
   - **替换拍照照片（含预览）**：可独立开启，在相机取景时直接显示已选照片，拍照结果也使用该图片。

两个开关共用同一张替换照片；任一开启即替换拍照结果。关闭“含预览”开关会恢复真实取景，若第一个开关仍开启则继续替换拍照结果。开关状态会保存，未选择照片时无法开启。

支持导入 JPEG、PNG、HEIC 等 ImageIO 能解码的图片；导入时修正 EXIF 方向，不缩放图像像素尺寸。选图按静态图片处理，不保留透明度或动画；保留所选照片中 ImageIO 支持写入的 EXIF、GPS、TIFF 等元数据（包括原有拍摄时间和相机信息），同时更新方向及 EXIF 像素尺寸，使其与方向修正后的图像一致。元数据随照片保存，重启或切换配置后继续保留；拍照的文件输出、`metadata` 接口和旧版照片回调也携带这些信息。未包含在原图中的信息不会补造。旧版本已经导入并丢失的 EXIF 需要重新选择原图才能恢复。预览替换支持 `AVCaptureVideoPreviewLayer`，沿用宿主的等比显示、等比填充或拉伸方式，随预览尺寸调整；更换所选照片会刷新已显示的预览。正在处理的拍照使用拍照开始时的图片快照；切换图片或开关作用于后续拍照。

### 命名配置

在设置页的“配置管理”中点击“保存当前配置…”，输入 1～40 个字符的名称保存。配置包含所选照片、两个相机开关、模拟定位开关和经纬度；每套配置独立保留自己的照片。

- **编辑已有配置**：点击名称加载，修改上方照片、开关或定位，再点“保存当前配置…”。输入框自动填入当前配置名称，确认覆盖后更新原配置。
- **另存为**：保存时输入新名称，创建独立配置。
- **更新指定配置**：点击该配置右侧按钮，选择“用当前设置更新”，确认后用当前照片和设置覆盖它。
- **重命名**：点击右侧按钮选择“重命名”。已有名称会拒绝使用，避免覆盖其他配置。
- **删除**：点击右侧按钮选择“删除配置”，或向左滑动该配置选择“删除”。确认后移除保存项，当前已加载的照片和开关继续生效。

点击已保存的配置名称即可切换，设置页和已显示的替换预览会自动更新。当前配置名称及切换后的设置会保存，重新启动 App 后可继续编辑。保存、更新或删除弹窗关闭后，仍可正常关闭并重新打开设置页。配置只保存在当前 App 沙盒内，不包含悬浮球位置。正在进行的拍照仍使用开始时的照片快照。

### 模拟定位

1. 打开“选择位置 / 地图预览”。
2. 长按地图选点，或输入纬度和经度，点击“预览输入的位置”。
3. 点击“保存”，回到设置页开启“模拟定位”。

经纬度输入使用英文小数点，纬度范围 `[-90, 90]`，经度范围 `[-180, 180]`。精确测试建议输入已知 WGS-84 经纬度；地图显示可能受到地图供应商的区域坐标偏移影响。

App 仍需要正常获得系统定位授权。库不会申请额外授权或修改授权状态。连续定位时约每秒补发当前位置，返回新的时间戳与 5 米水平精度。关闭模拟后恢复原始位置读取与系统回调；App 已缓存的旧位置需等待其下一次刷新。

照片、开关、坐标与悬浮球位置均保存在当前 App 沙盒内，互不跨 App 共享。

## 接口范围与兼容限制

| 功能 | 覆盖范围 |
| --- | --- |
| 相机预览替换 | `AVCaptureVideoPreviewLayer` 显示静态替换照片，保留宿主相机控件与触摸交互 |
| 常用现代拍照 | `AVCapturePhotoOutput capturePhotoWithSettings:delegate:` 与 `AVCapturePhoto` 的文件、CGImage、pixel buffer 读取接口 |
| 延迟照片 | iOS 17+ 的 `AVCaptureDeferredPhotoProxy` 回调 |
| 旧版静态拍照 | `AVCaptureStillImageOutput` 异步拍照与旧式 PhotoOutput sample buffer 回调 |
| 定位 | `CLLocationManager.location`、`requestLocation`、`startUpdatingLocation` 及现代/旧版位置 delegate 回调 |
| 悬浮入口 | 独立透明窗口，支持普通 App 页面、多 UIWindowScene、旋转和边缘吸附 |

下列路径需要针对目标 App 另行适配：

- 从 `AVCaptureVideoDataOutput` 实时视频帧截图、自有 GPU/Metal 图像处理链、视频录制、ARKit。
- RAW / ProRAW、Live Photo 视频部分、深度信息、相机校准数据、HDR / 增益图。RAW 路径保留原行为。
- 新版 Swift `CLLocationUpdate.liveUpdates`、地理围栏、区域监控、航向、基站/IP 定位及第三方自行实现的定位数据源。
- 宿主重写相关方法、不调用被 Hook 的基础实现，或自行做额外的照片/位置校验。

本库在标准相机预览层显示替换图片，并在照片处理和位置回调边界替换数据，不保证所有以 `AVCaptureSession` 为基础的采集方式都自动兼容。自有 GPU/Metal 等预览需要另行适配。系统真实相机仍须正常启动，照片捕获失败时保留原错误。

## 交互处理

- 悬浮层本身保持透明。设置页关闭时，窗口仅在悬浮图标的 44 × 44 pt 区域接收触摸，其他位置返回 nil，让宿主窗口处理。
- 设置页和导航栏使用不透明的系统分组背景，避免宿主界面透出。
- 普通悬浮状态不抢占 keyWindow；打开设置时临时切换，以支持文本输入，关闭后恢复宿主窗口。
- 点击图标打开设置与拖动图标分离；拖动限于安全区域，旋转后重新布局。
- 打开设置期间，设置页和地图正常接收触摸。App 可继续处理其他系统事件。

## 模拟器验证

附带一个真正加载动态库的 UIKit 测试宿主，bundle id 为 `dev.msbtweak.testhost`。它验证窗口穿透、设置页面、图片导入、照片 EXIF、照片回调适配、相机预览替换、命名配置保存与切换，以及 Core Location 回调。相机样本使用构造数据测试，不代表真机拍摄已验证。

```sh
make -C Tests
xcrun simctl list devices available
# 将 DEVICE_ID 替换为可用 iPhone 模拟器 UDID。
xcrun simctl boot DEVICE_ID
xcrun simctl install DEVICE_ID build/tests/MSBTweakTestHost.app
xcrun simctl privacy DEVICE_ID grant location dev.msbtweak.testhost
xcrun simctl launch --terminate-running-process DEVICE_ID dev.msbtweak.testhost
```

测试完成后，宿主沙盒的 `Documents/test-results.json` 包含检查结果。用下面的命令查询沙盒路径：

```sh
xcrun simctl get_app_container DEVICE_ID dev.msbtweak.testhost data
```

最近一次本地验证中，真机库通过架构、动态依赖和签名检查；模拟器宿主完成 105 项检查且无失败。同一套命令会在 GitHub Actions 中自动执行。实际设备、目标 App 和 TrollFools 注入链路仍需真机确认。

## 源码

类型、函数和静态符号使用 `MSB` 前缀，交换进去的方法使用 `msb_` 前缀。偏好、悬浮球位置等持久化键仍以 `MSBTweak.` 开头。

- `Sources/MSBTweakEntry.m`：动态库加载入口。
- `Sources/MSBTweakHooks.m`：无需外部 Hook 框架的方法交换。
- `Sources/MSBTweakCameraHooks.m`：照片捕获代理和图像结果替换。
- `Sources/MSBTweakCameraPreviewHooks.m`：标准相机预览层的替换照片显示与同步刷新。
- `Sources/MSBTweakLocationHooks.m`：定位代理、RunLoop 回调与连续模拟。
- `Sources/MSBTweakSettings.m`：线程同步、图片导入、设置持久化与命名配置保存/切换。
- `Sources/MSBTweakOverlay.m`：悬浮窗口、拖动、触摸穿透与焦点恢复。
- `Sources/MSBTweakSettingsController.m`：照片选择、缩略图、地图和经纬度编辑。
