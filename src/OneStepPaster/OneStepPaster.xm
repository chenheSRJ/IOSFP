//
//  OneStepPaster.xm —— 注入到各 App 进程的「粘贴助手」
//
//  职责：
//   1. 收到/检测到来自 SpringBoard 的拖放载荷（目标是自己）时：
//      a. 若输入框已是第一响应者 → 延时后自动粘贴
//      b. 否则显示悬浮胶囊「点此粘贴」；用户点输入框键盘出现后再自动粘贴
//      c. 粘贴成功后：还原用户原本的剪贴板、清空载荷、回报 SpringBoard
//   2. Hook UIPasteboard 写路径：把各 App 进程内的拷贝上报为剪贴板历史
//
//  filter：OneStepPaster.plist（全局注入）。安全护栏见下：
//   - 仅主 bundle 类型为 APPL（真正的 App）时注册业务观察者；
//     系统守护进程/扩展注入后空转，无副作用。
//

#import <UIKit/UIKit.h>
#import <objc/message.h>
#import "OSPasteHistory.h"
#import "OSCommon.h"

// ---------------------------------------------------------------------------
#pragma mark - 进程护栏

static BOOL OSIsAppProcess(void) {
    static BOOL cached = NO;
    static BOOL resolved = NO;
    if (!resolved) {
        resolved = YES;
        NSString *type = [[NSBundle mainBundle]
                          objectForInfoDictionaryKey:@"CFBundlePackageType"];
        cached = [type isEqualToString:@"APPL"];
    }
    return cached;
}

static NSString *OSCurrentBundleID(void) {
    return [NSBundle mainBundle].bundleIdentifier ?: @"";
}

// ---------------------------------------------------------------------------
#pragma mark - 浮动胶囊（粘贴兜底 UI）

@interface OSPasteBubble : UIView
@property (nonatomic, copy) void (^onTap)(void);
@property (nonatomic, strong) UILabel *label;
@end

@implementation OSPasteBubble

- (instancetype)initWithText:(NSString *)text {
    CGFloat w = 240;
    self = [super initWithFrame:CGRectMake(0, 0, w, 40)];
    if (self) {
        self.backgroundColor = [UIColor colorWithWhite:0.08 alpha:0.92];
        self.layer.cornerRadius = 20;
        self.layer.shadowColor = [UIColor blackColor].CGColor;
        self.layer.shadowOpacity = 0.3;
        self.layer.shadowRadius = 8;
        self.layer.shadowOffset = CGSizeMake(0, 3);

        _label = [[UILabel alloc] initWithFrame:CGRectInset(self.bounds, 14, 0)];
        _label.text = text;
        _label.font = [UIFont systemFontOfSize:13 weight:UIFontWeightMedium];
        _label.textColor = [UIColor whiteColor];
        _label.textAlignment = NSTextAlignmentCenter;
        _label.userInteractionEnabled = NO;
        [self addSubview:_label];

        UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc]
                                        initWithTarget:self
                                        action:@selector(_tapped)];
        [self addGestureRecognizer:tap];
    }
    return self;
}

- (void)setText:(NSString *)text {
    _label.text = text;
}

- (void)_tapped {
    if (self.onTap) self.onTap();
}

@end

// ---------------------------------------------------------------------------
#pragma mark - 粘贴引擎

@interface OSPasteEngine : NSObject
+ (instancetype)shared;
- (void)registerObservers;
- (void)applicationDidBecomeActive;
- (void)keyboardDidShow;
- (void)pasteboardWasWritten:(UIPasteboard *)pb; // 剪贴板钩子回调
@end

@implementation OSPasteEngine {
    NSString *_handledToken;   // 已处理的载荷时间戳，防重复
    BOOL _bubbleVisible;
    BOOL _sessionLive;
    NSTimer *_sessionTimer;    // 会话超时清理
}

+ (instancetype)shared {
    static OSPasteEngine *s = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        s = [[OSPasteEngine alloc] init];
    });
    return s;
}

- (void)registerObservers {
    NSNotificationCenter *nc = [NSNotificationCenter defaultCenter];
    [nc addObserver:self
           selector:@selector(_noteBecameActive:)
               name:UIApplicationDidBecomeActiveNotification object:nil];
    [nc addObserver:self
           selector:@selector(_noteKeyboard:)
               name:UIKeyboardDidShowNotification object:nil];

    CFNotificationCenterRef c = CFNotificationCenterGetDarwinNotifyCenter();
    CFNotificationCenterAddObserver(c, (__bridge const void *)self,
        PasterDarwinCallback, (__bridge CFStringRef)OSNotifyDragLaunched,
        NULL, CFNotificationSuspensionBehaviorDeliverImmediately);
}

static void PasterDarwinCallback(CFNotificationCenterRef center, void *observer,
                                 CFStringRef name, const void *object,
                                 CFDictionaryRef userInfo) {
    OSPasteEngine *engine = (__bridge OSPasteEngine *)observer;
    dispatch_async(dispatch_get_main_queue(), ^{
        [engine applicationDidBecomeActive];
    });
}

// ---------------------------------------------------------------------------
#pragma mark - 会话生命周期

- (void)_noteBecameActive:(NSNotification *)note {
    [self applicationDidBecomeActive];
}

- (void)applicationDidBecomeActive {
    if (!OSEnabled() || !OSIsAppProcess()) return;
    NSDictionary *payload = [self _readPayload];
    if (!payload) return;

    NSString *target = payload[OSPlTargetBundleID];
    NSString *selfBID = OSCurrentBundleID();
    if (target.length == 0 || !OSStrEq(target, selfBID)) return;

    NSNumber *tsNum = payload[OSPlTimestamp];
    double ts = tsNum ? tsNum.doubleValue : 0;
    double age = [NSDate date].timeIntervalSince1970 - ts;
    if (age < 0 || age > 15.0) return; // 只处理“刚刚”发起的拖放

    NSString *token = [NSString stringWithFormat:@"%.0f", ts];
    if (_handledToken && OSStrEq(_handledToken, token)) return;
    _handledToken = token;

    _sessionLive = YES;
    [self _restartSessionTimer];

    OSLog(@"Paster: 收到载荷 target=%@ kind=%@", target, payload[OSPlKind]);
    // 稍等目标 App 完成首屏
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                 (int64_t)(0.9 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        if (self->_sessionLive) [self attemptPasteFromAuto:YES];
    });
}

- (void)keyboardDidShow {
    // 键盘出现 → 说明输入框已聚焦，尝试自动粘贴
    if (_sessionLive) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                     (int64_t)(0.4 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            if (self->_sessionLive) [self attemptPasteFromAuto:YES];
        });
    }
}

- (void)_noteKeyboard:(NSNotification *)note {
    [self keyboardDidShow];
}

// ---------------------------------------------------------------------------
#pragma mark - 粘贴

/// 找到 keyWindow 内第一响应者视图
static UIView *OSFirstResponderView(UIView *view) {
    if (!view) return nil;
    if (view.isFirstResponder) return view;
    for (UIView *sub in view.subviews) {
        UIView *r = OSFirstResponderView(sub);
        if (r) return r;
    }
    return nil;
}

static BOOL OSTextInput(UIResponder *r) {
    return [r conformsToProtocol:@protocol(UITextInput)]
        || [r conformsToProtocol:@protocol(UIKeyInput)];
}

- (void)attemptPasteFromAuto:(BOOL)autoMode {
    if (!_sessionLive) return;

    NSDictionary *payload = [self _readPayload];
    if (!payload) {
        [self _finishSession]; // 载荷已被清（例如重试窗口过后）
        return;
    }

    UIWindow *keyWindow = [UIApplication sharedApplication].keyWindow;
    if (!keyWindow) {
        keyWindow = [UIApplication sharedApplication].windows.firstObject;
    }
    UIView *responder = OSFirstResponderView(keyWindow);

    if (responder && OSTextInput(responder)) {
        BOOL ok = [[UIApplication sharedApplication]
                   sendAction:@selector(paste:) to:nil from:responder forEvent:nil];
        OSLog(@"Paster: sendAction paste → %d", ok);
        if (ok) {
            [self _restoreClipboardFromPayload:payload];
            [self _clearPayloadPasteboard];
            [self _hideBubble];
            [self _finishSession];
            CFNotificationCenterPostNotification(
                CFNotificationCenterGetDarwinNotifyCenter(),
                (__bridge CFStringRef)OSNotifyPasteFinished, NULL, NULL, YES);
            return;
        }
    }

    // 还没有可用输入框：给出兜底气泡
    if (!_bubbleVisible && autoMode) {
        [self _showBubble];
    }
}

- (void)_bubbleTapped {
    if (!_sessionLive) return;
    // 用户可能已点开输入框；直接尝试
    NSDictionary *payload = [self _readPayload];
    UIWindow *keyWindow = [UIApplication sharedApplication].keyWindow
        ?: [UIApplication sharedApplication].windows.firstObject;
    UIView *responder = OSFirstResponderView(keyWindow);
    if (responder && OSTextInput(responder)) {
        [self attemptPasteFromAuto:NO];
    } else {
        OSPasteBubble *bubble = [self _visibleBubble];
        [bubble setText:@"请先点一下输入框，将自动粘贴"];
        if (payload && payload[OSPlKind]) {
            // 再次排程一次自动尝试
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                         (int64_t)(1.2 * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{
                [self attemptPasteFromAuto:YES];
            });
        }
    }
}

// ---------------------------------------------------------------------------
#pragma mark - 还原 / 清理

- (void)_restoreClipboardFromPayload:(NSDictionary *)payload {
    NSArray *originals = payload[OSPlOriginalItems];
    BOOL restore = YES;
    NSNumber *r = [OSPrefs() objectForKey:OSKeyRestoreClipboardAfterPaste];
    if (r) restore = r.boolValue;
    if (!restore || ![originals isKindOfClass:NSArray.class]) return;
    [UIPasteboard generalPasteboard].items = originals;
}

- (void)_clearPayloadPasteboard {
    UIPasteboard *pb = [UIPasteboard pasteboardWithName:OSPayloadPasteboardName
                                                 create:YES];
    pb.items = @[];
}

- (void)_finishSession {
    _sessionLive = NO;
    [self _stopSessionTimer];
}

- (void)_restartSessionTimer {
    [self _stopSessionTimer];
    _sessionTimer = [NSTimer scheduledTimerWithTimeInterval:20.0
                                                     target:self
                                                   selector:@selector(_sessionTimedOut)
                                                   userInfo:nil repeats:NO];
}

- (void)_stopSessionTimer {
    [_sessionTimer invalidate];
    _sessionTimer = nil;
}

- (void)_sessionTimedOut {
    _sessionLive = NO;
    [self _hideBubble];
    [self _clearPayloadPasteboard];
}

// ---------------------------------------------------------------------------
#pragma mark - 气泡

- (OSPasteBubble *)_visibleBubble {
    for (UIWindow *w in [UIApplication sharedApplication].windows) {
        for (UIView *v in w.subviews) {
            if ([v isKindOfClass:OSPasteBubble.class]) return (OSPasteBubble *)v;
        }
    }
    return nil;
}

- (void)_showBubble {
    [self _hideBubble];
    OSPasteBubble *bubble = [[OSPasteBubble alloc]
                             initWithText:@"一步：点此粘贴"];
    __weak typeof(self) weakSelf = self;
    bubble.onTap = ^{
        [weakSelf _bubbleTapped];
    };

    UIWindow *w = [UIApplication sharedApplication].keyWindow
        ?: [UIApplication sharedApplication].windows.firstObject;
    if (!w) return;

    CGSize ws = w.bounds.size;
    CGFloat bx = (ws.width - bubble.bounds.size.width) / 2;
    CGFloat by = ws.height - 120;
    // 键盘遮挡时上移（简单估算）
    CGRect kb = [w convertRect:[self _keyboardFrame] fromView:nil];
    if (kb.size.height > 0 && kb.origin.y < ws.height) {
        by = kb.origin.y - bubble.bounds.size.height - 12;
    }
    bubble.frame = CGRectMake(bx, by, bubble.bounds.size.width,
                              bubble.bounds.size.height);
    bubble.alpha = 0;
    [w addSubview:bubble];
    _bubbleVisible = YES;
    [UIView animateWithDuration:0.2 animations:^{ bubble.alpha = 1; }];
}

- (void)_hideBubble {
    OSPasteBubble *bubble = [self _visibleBubble];
    if (!bubble) {
        _bubbleVisible = NO;
        return;
    }
    _bubbleVisible = NO;
    [UIView animateWithDuration:0.15 animations:^{
        bubble.alpha = 0;
    } completion:^(BOOL f) {
        [bubble removeFromSuperview];
    }];
}

- (CGRect)_keyboardFrame {
    // 通过可见键盘 window 反推（无私有 API）
    CGRect frame = CGRectZero;
    for (UIWindow *w in [UIApplication sharedApplication].windows) {
        NSString *cls = NSStringFromClass(w.class);
        if ([cls containsString:@"Keyboard"] ||
            [cls containsString:@"TextEffect"]) {
            frame = w.frame;
            break;
        }
    }
    return frame;
}

// ---------------------------------------------------------------------------
#pragma mark - 载荷读取

- (NSDictionary *)_readPayload {
    UIPasteboard *pb = [UIPasteboard pasteboardWithName:OSPayloadPasteboardName
                                                 create:NO];
    if (!pb) return nil;
    NSArray *its = pb.items;
    if (!its.count) return nil;
    NSDictionary *first = its.firstObject;
    NSData *data = first[OSPayloadUTI];
    if (![data isKindOfClass:NSData.class] || !data.length) return nil;
    NSError *err = nil;
    id obj = [NSKeyedUnarchiver unarchiveTopLevelObjectWithData:data error:&err];
    if (err || ![obj isKindOfClass:NSDictionary.class]) return nil;

    // 把第二 item（原剪贴板内容）合并进 dict，供粘贴后还原
    NSMutableDictionary *merged = [obj mutableCopy];
    if (its.count > 1) {
        NSDictionary *second = its[1];
        NSArray *originals = second[OSOriginalUTI];
        if ([originals isKindOfClass:NSArray.class]) {
            merged[OSPlOriginalItems] = originals;
        }
    }
    return merged;
}

// ---------------------------------------------------------------------------
#pragma mark - 剪贴板写上报

- (void)pasteboardWasWritten:(UIPasteboard *)pb {
    if (pb != [UIPasteboard generalPasteboard]) return;
    NSString *s = pb.string;
    if (s.length > 0) {
        // 防呆：跳过长度过大的内容
        NSString *trimmed = s.length > 3000 ? [s substringToIndex:3000] : s;
        [[OSPasteHistory shared] addText:trimmed];
        CFNotificationCenterPostNotification(
            CFNotificationCenterGetDarwinNotifyCenter(),
            (__bridge CFStringRef)OSNotifyClipboardChanged, NULL, NULL, YES);
    }
}

@end

// ---------------------------------------------------------------------------
#pragma mark - 剪贴板 Hook

%hook UIPasteboard

- (void)setItems:(NSArray *)items options:(NSDictionary *)options {
    %orig;
    if (OSIsAppProcess()) [[OSPasteEngine shared] pasteboardWasWritten:self];
}
- (void)setItems:(NSArray *)items {
    %orig;
    if (OSIsAppProcess()) [[OSPasteEngine shared] pasteboardWasWritten:self];
}
- (void)setObjects:(NSArray *)objects options:(NSDictionary *)options {
    %orig;
    if (OSIsAppProcess()) [[OSPasteEngine shared] pasteboardWasWritten:self];
}
- (void)setString:(NSString *)string {
    %orig;
    if (OSIsAppProcess()) [[OSPasteEngine shared] pasteboardWasWritten:self];
}

%end

// ---------------------------------------------------------------------------
#pragma mark - 注入入口

%ctor {
    if (!OSIsAppProcess()) return; // 守护进程/扩展：直接空转
    dispatch_async(dispatch_get_main_queue(), ^{
        [[OSPasteEngine shared] registerObservers];
    });
}
