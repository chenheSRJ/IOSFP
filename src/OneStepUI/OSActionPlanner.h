//
//  OSActionPlanner.h
//  动作执行链：把拖拽载荷送到目标 App / 快捷动作。
//

#import <UIKit/UIKit.h>

@class OSDragPayload;
@class OSAppItem;
@class OSActionItem;

NS_ASSUME_NONNULL_BEGIN

@interface OSActionPlanner : NSObject

+ (instancetype)shared;

/// 用于弹出系统分享面板的 Presenter（由 OSUIManager 注入为 overlay 的 root VC）
@property (nonatomic, weak, nullable) UIViewController *presenter;

/// 把一个载荷送到某个 App（写剪贴板 + 写 payload 板 + 拉起 + 广播）
- (void)deliverPayload:(OSDragPayload *)payload toAppBundleID:(NSString *)bundleID
           appName:(NSString *)appName;

/// 送到快捷动作（搜索 / 分享 / 邮件）
- (void)deliverPayload:(OSDragPayload *)payload toAction:(OSActionItem *)action;

/// 点击剪贴板历史条：复制回剪贴板
- (void)copyTextToClipboard:(NSString *)text;

@end

NS_ASSUME_NONNULL_END
