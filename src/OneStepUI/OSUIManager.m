//
//  OSUIManager.m
//  主控实现：
//   - 生命周期：跟随 SpringBoard 前台/退场收起与刷新
//   - 数据流：剪贴板历史 / 相册 / 应用列表 → 面板
//   - 拖放编排：OSPanelController(手势源) ⇄ OSDragController(状态机)
//                ⇄ OSActionPlanner(执行)
//   - Darwin 通知：收 Paster 的剪贴板上报 / 粘贴完成
//

#import "OSUIManager.h"
#import "OSPanelController.h"
#import "OSDragController.h"
#import "OSActionPlanner.h"
#import "OSAppSource.h"
#import "OSPhotosSource.h"
#import "OSPasteHistory.h"
#import "OSModels.h"
#import "OSRuntime.h"
#import "OSCommon.h"

@implementation OSUIManager {
    UIWindow *_overlayWindow;
    OSPanelController *_panel;
    OSDragController *_drag;
    BOOL _started;
    BOOL _waitingForUI;
}

+ (instancetype)shared {
    static OSUIManager *s = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        s = [[OSUIManager alloc] init];
    });
    return s;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _drag = [OSDragController new];
        _drag.delegate = (id<OSDragControllerDelegate>)self;
    }
    return self;
}

- (BOOL)isStarted {
    return _started;
}

// ---------------------------------------------------------------------------
#pragma mark - 启动

- (void)start {
    if (_started || _waitingForUI) return;
    _waitingForUI = YES;
    if (!OSEnabled()) { // 偏好里被关闭
        _waitingForUI = NO;
        OSLog(@"OSUIManager: 已通过偏好关闭，跳过启动");
        return;
    }

    dispatch_async(dispatch_get_main_queue(), ^{
        // SpringBoard 早期 UIWindow/Scene 可能未就绪：短轮询
        __block NSInteger tries = 0;
        [self _pollUntilReady:^{
            tries++;
            return (BOOL)(tries < 20 &&
                          [UIApplication sharedApplication].windows.count == 0);
        } then:^{
            self->_waitingForUI = NO;
            [self _buildUI];
            self->_started = YES;
            [self _registerObservers];
            OSLog(@"OSUIManager 已启动");
        }];
    });
}

- (void)_pollUntilReady:(BOOL (^)(void))cond then:(void (^)(void))done {
    if (!cond()) {
        done();
        return;
    }
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                 (int64_t)(0.3 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        if (!cond()) {
            done();
            return;
        }
        [self _pollUntilReady:cond then:done];
    });
}

- (void)stop {
    if (!_started) return;
    [self _unregisterObservers];
    [_overlayWindow setHidden:YES];
    _overlayWindow.rootViewController = nil;
    _overlayWindow = nil;
    _panel = nil;
    _started = NO;
}

// ---------------------------------------------------------------------------
#pragma mark - UI 构建

- (void)_buildUI {
    _overlayWindow = [self _makeOverlayWindow];
    if (!_overlayWindow) {
        OSLog(@"OSUIManager: 无法创建浮层窗口（无可用 scene）");
        _started = NO;
        return;
    }

    _panel = [OSPanelController new];
    _panel.delegate = (id<OSPanelControllerDelegate>)self;
    _overlayWindow.rootViewController = _panel;
    [_overlayWindow setHidden:NO];

    [OSActionPlanner shared].presenter = _panel;
}

/// 创建浮层窗口：优先绑定活跃 UIWindowScene，退化为无 scene 传统窗口
- (UIWindow *)_makeOverlayWindow {
    UIWindowScene *activeScene = nil;
    if (@available(iOS 13.0, *)) {
        for (UIScene *s in [UIApplication sharedApplication].connectedScenes) {
            if ([s isKindOfClass:UIWindowScene.class]) {
                UIWindowScene *ws = (UIWindowScene *)s;
                if (ws.activationState == UISceneActivationStateForegroundActive) {
                    activeScene = ws;
                    break;
                }
            }
        }
        if (!activeScene) {
            activeScene = (UIWindowScene *)
                [[[UIApplication sharedApplication] connectedScenes] anyObject];
        }
    }

    UIWindow *w = nil;
    if (activeScene) {
        w = [[UIWindow alloc] initWithWindowScene:activeScene];
    } else {
        w = [[UIWindow alloc] initWithFrame:[UIScreen mainScreen].bounds];
    }
    w.windowLevel = UIWindowLevelStatusBar - 1; // 状态栏之下、桌面内容之上
    w.backgroundColor = [UIColor clearColor];
    return w;
}

// ---------------------------------------------------------------------------
#pragma mark - 观察者

- (void)_registerObservers {
    NSNotificationCenter *nc = [NSNotificationCenter defaultCenter];

    // 回到桌面（或 app 切回）→ 刷新托盘
    [nc addObserver:self selector:@selector(_appDidBecomeActive)
               name:UIApplicationDidBecomeActiveNotification object:nil];
    [nc addObserver:self selector:@selector(_appWillResignActive)
               name:UIApplicationWillResignActiveNotification object:nil];

    // 相册数据变化（授权后）
    [OSPhotosSource shared].onChange = ^{
        [self->_panel reloadAllData];
    };
    // 本进程剪贴板钩子写入历史后
    [OSPasteHistory shared].onChange = ^{
        [self->_panel reloadClipboardOnly];
    };

    // 跨进程 Darwin
    CFNotificationCenterRef c = CFNotificationCenterGetDarwinNotifyCenter();
    CFNotificationCenterAddObserver(c, (__bridge const void *)self,
        OSHandleDarwinNote, (__bridge CFStringRef)OSNotifyClipboardChanged,
        NULL, CFNotificationSuspensionBehaviorDeliverImmediately);
    CFNotificationCenterAddObserver(c, (__bridge const void *)self,
        OSHandleDarwinNote, (__bridge CFStringRef)OSNotifyPasteFinished,
        NULL, CFNotificationSuspensionBehaviorDeliverImmediately);
}

- (void)_unregisterObservers {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    CFNotificationCenterRemoveEveryObserver(
        CFNotificationCenterGetDarwinNotifyCenter(), (__bridge const void *)self);
}

static void OSHandleDarwinNote(CFNotificationCenterRef center, void *observer,
                               CFStringRef name, const void *object,
                               CFDictionaryRef userInfo) {
    NSString *n = (__bridge NSString *)name;
    dispatch_async(dispatch_get_main_queue(), ^{
        if ([n isEqualToString:OSNotifyClipboardChanged]) {
            [[OSPasteHistory shared] reload]; // → onChange → 面板刷新
        } else if ([n isEqualToString:OSNotifyPasteFinished]) {
            OSLog(@"收到 Paster 粘贴完成回报");
        }
    });
}

- (void)_appDidBecomeActive {
    if (!_started) return;
    [_overlayWindow setHidden:NO];
    // 剪贴板历史刷新 + 相册授权联动/拉取（完成后经 onChange 再刷新面板）
    [_panel reloadClipboardOnly];
    [[OSPhotosSource shared] refresh];
}

- (void)_appWillResignActive {
    if (!_started) return;
    [_panel setExpanded:NO animated:NO];
}

// ---------------------------------------------------------------------------
#pragma mark - OSPanelControllerDelegate

- (void)panel:(OSPanelController *)panel
    didBeginDragWithPayload:(OSDragPayload *)payload
                   snapshot:(UIView *)snapshot
              atWindowPoint:(CGPoint)point {
    if (!_drag.isDragging) {
        [_drag startDragWithPayload:payload snapshot:snapshot
                      atWindowPoint:point inWindow:_overlayWindow];
    }
}

- (void)panel:(OSPanelController *)panel dragMovedToWindowPoint:(CGPoint)point {
    [_drag updateDragAtWindowPoint:point];
}

- (void)panel:(OSPanelController *)panel dragEndedAtWindowPoint:(CGPoint)point
    cancelled:(BOOL)cancelled {
    if (cancelled) {
        [_drag cancelDrag];
    } else {
        [_drag endDragAtWindowPoint:point];
    }
    [panel restoreSourceHighlight];
}

- (void)panel:(OSPanelController *)panel didTapClipText:(NSString *)text {
    [[OSActionPlanner shared] copyTextToClipboard:text];
    [self showToast:@"已复制到剪贴板"];
}

- (void)panel:(OSPanelController *)panel didTriggerAction:(OSActionItem *)action {
    // 动作行点击：取最近一条剪贴板文本作为内容
    NSDictionary *top = [OSPasteHistory shared].items.firstObject;
    NSString *text = top[OSHistoryKeyText];
    if (![text isKindOfClass:NSString.class] || text.length == 0) {
        [self showToast:@"没有可用文本，请先复制内容"];
        return;
    }
    OSDragPayload *p = [OSDragPayload new];
    p.kind = OSItemKindText;
    p.text = text;
    p.sourceTitle = @"剪贴板";
    [[OSActionPlanner shared] deliverPayload:p toAction:action];
}

- (void)panelDidRequestClose:(OSPanelController *)panel {
    // 面板自身已完成收起动画
}

// ---------------------------------------------------------------------------
#pragma mark - OSDragControllerDelegate

- (id)dragControllerDropTargetAtWindowPoint:(CGPoint)p {
    return [_panel dropTargetAtWindowPoint:p];
}

- (void)dragControllerHighlightTarget:(id)target {
    [_panel highlightTarget:target];
}

- (void)dragController:(OSDragController *)dc
         didDropOnTarget:(id)target payload:(OSDragPayload *)payload {
    [_panel setExpanded:NO animated:YES];

    if ([target isKindOfClass:OSAppItem.class]) {
        OSAppItem *app = (OSAppItem *)target;
        [[OSActionPlanner shared] deliverPayload:payload
                                    toAppBundleID:app.bundleID
                                          appName:app.displayName];
        [self showToast:[NSString stringWithFormat:@"正在发送到「%@」…",
                         app.displayName.length ? app.displayName : app.bundleID]];
    } else if ([target isKindOfClass:OSActionItem.class]) {
        OSActionItem *action = (OSActionItem *)target;
        [[OSActionPlanner shared] deliverPayload:payload toAction:action];
        [self showToast:@"已执行操作"];
    }
}

- (void)dragControllerDidCancel:(OSDragController *)dc {
    // 保持面板展开，用户可再拖
}

// ---------------------------------------------------------------------------
#pragma mark - 轻提示

- (void)showToast:(NSString *)message {
    if (!_overlayWindow || message.length == 0) return;

    UIView *host = _overlayWindow;
    // 清掉旧 toast
    UIView *old = [host viewWithTag:0x4F53]; // "OS"
    [old removeFromSuperview];

    UILabel *label = [[UILabel alloc] initWithFrame:CGRectZero];
    label.tag = 0x4F53;
    label.text = message;
    label.font = [UIFont systemFontOfSize:13 weight:UIFontWeightMedium];
    label.textColor = [UIColor whiteColor];
    label.backgroundColor = [UIColor colorWithWhite:0.1 alpha:0.88];
    label.layer.cornerRadius = 16;
    label.clipsToBounds = YES;
    label.textAlignment = NSTextAlignmentCenter;
    label.numberOfLines = 0;

    CGRect b = host.bounds;
    CGFloat w = MIN(b.size.width - 40, 320);
    CGSize fit = [label sizeThatFits:CGSizeMake(w - 28, 60)];
    label.frame = CGRectMake((b.size.width - fit.width - 28) / 2,
                             b.size.height * 0.78,
                             fit.width + 28, fit.height + 16);
    [host addSubview:label];

    [UIView animateWithDuration:0.2 animations:^{
        label.alpha = 0.9;
    }];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                 (int64_t)(1.8 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        [UIView animateWithDuration:0.3 animations:^{
            label.alpha = 0;
        } completion:^(BOOL f) {
            [label removeFromSuperview];
        }];
    });
}

@end
