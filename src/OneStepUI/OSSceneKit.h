//
//  OSSceneKit.h  ——  OneStep Split Scene 内核
//
//  能力（全部运行时私有 API，nil 安全，带 OSLog 诊断）：
//   - 按 bundleID 查找前台/后台 App 的 FBScene
//   - 把某 App 的实时画面 layer host 成一个 UIView（浮窗内容）
//   - 控制某 App scene 的 foreground 状态
//   - 每秒 keep-alive：防止后台 App 被挂起（小窗“实时运行”的关键）
//   - 识别当前前台 App
//

#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

@interface OSSceneKit : NSObject

/// 多策略查找 bundleID 对应的 FBScene（运行时对象）；失败返回 nil
+ (nullable id)fbSceneForBundleID:(NSString *)bundleID;

/// 为 bundleID 创建「外部 scene 实时画面」宿主视图；frame 生效；失败返回 nil
+ (nullable UIView *)layerHostViewForBundleID:(NSString *)bundleID frame:(CGRect)frame;

/// 设置某 App 的 scene foreground 状态
+ (void)setForeground:(BOOL)fg forBundleID:(NSString *)bundleID;

/// 启动/停止保活（每秒保持 foreground，防止挂起）。幂等。
+ (void)startKeepAliveForBundleID:(NSString *)bundleID;
+ (void)stopKeepAliveForBundleID:(NSString *)bundleID;

/// 当前前台 App 的 bundleID（SBApplicationController isForeground 遍历）
+ (nullable NSString *)frontmostAppBundleID;

/// 主屏 bounds（浮窗几何基准）
+ (CGRect)screenBounds;

@end

NS_ASSUME_NONNULL_END
