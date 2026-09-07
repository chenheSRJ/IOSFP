//
//  OSDragController.h
//  拖拽状态机：负责跟手浮层、目标命中查询与高亮、结束/取消收尾。
//  不含手势识别（手势源在托盘 cell 上，由面板转发位置到本控制器）。
//

#import <UIKit/UIKit.h>

@class OSDragPayload;

NS_ASSUME_NONNULL_BEGIN

@protocol OSDragControllerDelegate <NSObject>

/// 查询窗口坐标系某点的落点目标（OSAppItem / OSActionItem / nil）
- (nullable id)dragControllerDropTargetAtWindowPoint:(CGPoint)p;

/// 高亮/取消高亮目标
- (void)dragControllerHighlightTarget:(nullable id)target;

/// 松手并落在目标上（payload 交给执行层）
- (void)dragController:(id)dc didDropOnTarget:(id)target
               payload:(OSDragPayload *)payload;

/// 拖拽被取消/未命中任何目标
- (void)dragControllerDidCancel:(id)dc;

@end

@interface OSDragController : NSObject

@property (nonatomic, weak, nullable) id<OSDragControllerDelegate> delegate;
@property (nonatomic, readonly, getter=isDragging) BOOL dragging;

/// 开始拖拽（snapshot 可为 nil——表示仅执行不显示浮层）
- (void)startDragWithPayload:(OSDragPayload *)payload
                    snapshot:(nullable UIView *)snapshot
               atWindowPoint:(CGPoint)p
                    inWindow:(UIWindow *)window;

/// 跟随手指（window 坐标）
- (void)updateDragAtWindowPoint:(CGPoint)p;

/// 手指抬起
- (void)endDragAtWindowPoint:(CGPoint)p;

/// 取消（浮层消失）
- (void)cancelDrag;

@end

NS_ASSUME_NONNULL_END
