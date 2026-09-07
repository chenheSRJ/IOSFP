//
//  OSPanelController.h
//  OneStep 主面板：右缘把手 + 展开面板（顶部托盘 + 应用网格 + 快捷动作）。
//  纯 UI 与命中检测；拖拽状态机与动作执行由 OSUIManager / OSDragController 负责。
//

#import <UIKit/UIKit.h>

@class OSDragPayload;
@class OSAppItem;
@class OSActionItem;

NS_ASSUME_NONNULL_BEGIN

@protocol OSPanelControllerDelegate <NSObject>

/// 托盘条目长按开始拖拽（snapshot 已生成，point 为 window 坐标）
- (void)panel:(id)panel didBeginDragWithPayload:(OSDragPayload *)payload
         snapshot:(UIView *)snapshot atWindowPoint:(CGPoint)point;

/// 拖拽进行中（跟随手指移动）
- (void)panel:(id)panel dragMovedToWindowPoint:(CGPoint)point;

/// 拖拽结束（cancelled=YES 表示手势被取消，未落在目标上）
- (void)panel:(id)panel dragEndedAtWindowPoint:(CGPoint)point
    cancelled:(BOOL)cancelled;

/// 用户点了关闭 / 遮罩，请求收起
- (void)panelDidRequestClose:(id)panel;

/// 点击了某条剪贴板历史
- (void)panel:(id)panel didTapClipText:(NSString *)text;

/// 点击快捷动作（搜索/分享/邮件）；内容由上层取当前剪贴板首条决定
- (void)panel:(id)panel didTriggerAction:(OSActionItem *)action;

@end

@interface OSPanelController : UIViewController

@property (nonatomic, weak, nullable) id<OSPanelControllerDelegate> delegate;

@property (nonatomic, readonly, getter=isExpanded) BOOL expanded;

// ---------- 外观控制 ----------
- (void)setExpanded:(BOOL)expanded animated:(BOOL)animated;

// ---------- 数据刷新（由 manager 调用） ----------
- (void)reloadAllData; // 剪贴板历史 + 相册
- (void)reloadClipboardOnly;

// ---------- 拖放命中 ----------
/// 返回 window 坐标系下该点的落点目标：OSAppItem / OSActionItem / nil
- (nullable id)dropTargetAtWindowPoint:(CGPoint)p;
/// 高亮某个目标（nil 清除）
- (void)highlightTarget:(nullable id)target;

@end

NS_ASSUME_NONNULL_END
