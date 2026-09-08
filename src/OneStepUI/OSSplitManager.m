//
//  OSSplitManager.m  ——  分屏主控实现
//
//  P0 闭环（v0.3）：
//   「全屏主 App」 + 「1 个 scene-host 实时小浮窗」
//    1. 右上角分屏胶囊 → 弹出 App 选择列表
//    2. 选中某 App → 它以全屏启动；原前台 App 退为小浮窗（实时画面）
//    3. 点小浮窗 → 主副互换（浮窗 App 全屏，原主 App 缩小为浮窗）
//    4. 关闭按钮停止保活并移除浮窗
//  交互细节（拖动/角上滑/双浮窗/缩放）留待 P1/P2，真机反馈后迭代。
//

#import "OSSplitManager.h"
#import "OSCommon.h"
#import "OSDiag.h"
#import "OSRuntime.h"
#import "OSAppSource.h"
#import "OSModels.h"
#import "OSSceneKit.h"
#import <QuartzCore/QuartzCore.h>

// ---------------------------------------------------------------------------
#pragma mark - 穿透式根视图

@interface OSPassRootView : UIView
@property (nonatomic, weak) UIButton *pillButton;
@property (nonatomic, weak) UIView *floatView;
@property (nonatomic, weak) UIView *pickerLayer;
@end

@implementation OSPassRootView
- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    if (self.pickerLayer && !self.pickerLayer.hidden) {
        return [super hitTest:point withEvent:event]; // 选择器打开时全屏拦截
    }
    UIView *hit = [super hitTest:point withEvent:event];
    // 只允许 pill / 浮窗 / 它们的子视图被命中；其余区域穿透给下层
    UIView *walk = hit;
    while (walk) {
        if (walk == self.pillButton || walk == self.floatView) return hit;
        walk = walk.superview;
    }
    return nil;
}
@end

// ---------------------------------------------------------------------------
#pragma mark - 主控

@interface OSSplitManager () <UITableViewDataSource, UITableViewDelegate>
@property (nonatomic, strong) UIWindow *overlay;
@property (nonatomic, strong) OSPassRootView *rootView;
@property (nonatomic, strong) UIButton *pillButton;   // 分屏胶囊
@property (nonatomic, strong) UIButton *closeButton;  // 结束分屏
@property (nonatomic, strong) UIView *pickerLayer;    // 选择弹层
@property (nonatomic, strong) UITableView *pickerTable;
@property (nonatomic, strong) NSArray<OSAppItem *> *pickerApps;
@property (nonatomic, strong) UIView *floatView;      // 当前小窗
@property (nonatomic, copy, nullable) NSString *fullBid;   // 全屏 App
@property (nonatomic, copy, nullable) NSString *floatBid;  // 小窗 App
@property (nonatomic, assign) BOOL pickerOpen;
@end

/// 承载 rootView 的根 VC（loadView 直接挂载，避免系统默认 view 干扰）
@interface OSSplitRootVC : UIViewController
@property (nonatomic, strong) UIView *hostView;
@end
@implementation OSSplitRootVC
- (void)loadView {
    self.view = self.hostView ?: [UIView new];
}
@end

@implementation OSSplitManager

+ (instancetype)shared {
    static OSSplitManager *s = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ s = [[OSSplitManager alloc] init]; });
    return s;
}

// ---------------------------------------------------------------------------
#pragma mark - 生命周期

- (void)start {
    static BOOL started = NO;
    if (started) return;
    started = YES;

    dispatch_async(dispatch_get_main_queue(), ^{
        @try {
            OSLogF(@"[UI] start：进程 %@，windows=%lu",
                  [NSProcessInfo processInfo].processName,
                  (unsigned long)[UIApplication sharedApplication].windows.count);
            [self _buildUI];
            OSLogF(@"[UI] OSSplitManager 已启动");
            // scene/几何可能晚就绪：稍后强制重排一次，保证按钮在正确位置
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                         (int64_t)(1.0 * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{
                @try {
                    [self _layoutOverlayControls];
                    [self _diagnose];
                } @catch (NSException *e) {
                    OSLogF(@"[UI] 延迟重排异常：%@", e);
                }
            });
        } @catch (NSException *e) {
            OSLogF(@"[UI] OSSplitManager 启动异常（停用 UI）：%@", e);
            started = NO;
            [self _teardownUI];
        }
    });
}

- (void)_teardownUI {
    if (self.overlay) {
        [self.overlay setHidden:YES];
        self.overlay.rootViewController = nil;
        self.overlay = nil;
    }
    self.rootView = nil;
    self.pillButton = nil;
    self.floatView = nil;
    self.pickerLayer = nil;
}

/// 可见性自检（日志）
- (void)_diagnose {
    if (!self.overlay) { OSLogF(@"[UI] 诊断：overlay 为空"); return; }
    OSLogF(@"[UI] 诊断 overlay: hidden=%d frame=%@ level=%.1f keyWindow=%@",
          self.overlay.hidden, NSStringFromCGRect(self.overlay.frame),
          self.overlay.windowLevel,
          [UIApplication sharedApplication].keyWindow);
    OSLogF(@"[UI] 诊断 rootView: frame=%@ pill.frame=%@ pillHidden=%d",
          NSStringFromCGRect(self.rootView.frame),
          NSStringFromCGRect(self.pillButton.frame),
          self.pillButton.hidden);
    OSLogF(@"[UI] 诊断 scenes=%lu",
          (unsigned long)[UIApplication sharedApplication].connectedScenes.count);
}

- (UIWindow *)_makeOverlayWindow {
    UIWindowScene *scene = nil;
    if (@available(iOS 13.0, *)) {
        for (UIScene *s in [UIApplication sharedApplication].connectedScenes) {
            if ([s isKindOfClass:UIWindowScene.class]) { scene = (UIWindowScene *)s; break; }
        }
    }
    UIWindow *w = scene
        ? [[UIWindow alloc] initWithWindowScene:scene]
        : [[UIWindow alloc] initWithFrame:[UIScreen mainScreen].bounds];
    w.windowLevel = UIWindowLevelStatusBar - 1;
    w.backgroundColor = [UIColor clearColor];
    OSLogF(@"[UI] overlay 窗口创建: frame=%@", NSStringFromCGRect(w.frame));
    return w;
}

- (void)_buildUI {
    self.overlay = [self _makeOverlayWindow];
    self.overlay.frame = [UIScreen mainScreen].bounds;
    self.rootView = [[OSPassRootView alloc] initWithFrame:[UIScreen mainScreen].bounds];
    OSSplitRootVC *vc = [OSSplitRootVC new];
    vc.hostView = self.rootView;
    self.overlay.rootViewController = vc;
    [self.overlay setHidden:NO];
    [self.overlay makeKeyAndVisible]; // 探针：确保窗口进入显示链
    OSLogF(@"[UI] overlay makeKeyAndVisible 完成");

    // 分屏胶囊（右上角）
    self.pillButton = [UIButton buttonWithType:UIButtonTypeCustom];
    [self.pillButton setTitle:@"▣" forState:UIControlStateNormal];
    self.pillButton.titleLabel.font = [UIFont boldSystemFontOfSize:18];
    self.pillButton.backgroundColor = [UIColor colorWithWhite:0.1 alpha:0.72];
    self.pillButton.layer.cornerRadius = 18;
    self.pillButton.frame = CGRectMake(0, 0, 36, 36);
    [self.pillButton addTarget:self action:@selector(_pillTapped)
              forControlEvents:UIControlEventTouchUpInside];
    [self.rootView addSubview:self.pillButton];

    // 结束分屏（胶囊旁，有浮窗时才需要，固定显示）
    self.closeButton = [UIButton buttonWithType:UIButtonTypeSystem];
    [self.closeButton setTitle:@"✕" forState:UIControlStateNormal];
    self.closeButton.tintColor = [UIColor whiteColor];
    self.closeButton.backgroundColor = [UIColor colorWithWhite:0.1 alpha:0.72];
    self.closeButton.layer.cornerRadius = 14;
    self.closeButton.titleLabel.font = [UIFont boldSystemFontOfSize:14];
    self.closeButton.frame = CGRectMake(0, 0, 28, 28);
    [self.closeButton addTarget:self action:@selector(_closeSplit)
               forControlEvents:UIControlEventTouchUpInside];
    [self.rootView addSubview:self.closeButton];

    self.rootView.pillButton = self.pillButton;
    self.rootView.floatView = nil;

    [self _layoutOverlayControls];
    [self _buildPicker];
}

- (void)_layoutOverlayControls {
    CGRect b = self.overlay.bounds;
    UIEdgeInsets safe = self.rootView.safeAreaInsets;
    self.pillButton.frame = CGRectMake(b.size.width - 44 - 6, safe.top + 8, 36, 36);
    self.closeButton.frame = CGRectMake(b.size.width - 44 - 34, safe.top + 8, 28, 28);
    self.closeButton.hidden = (self.floatBid == nil);
}

// ---------------------------------------------------------------------------
#pragma mark - 选择器

- (void)_buildPicker {
    CGRect b = self.overlay.bounds;
    self.pickerLayer = [[UIView alloc] initWithFrame:b];
    self.pickerLayer.backgroundColor = [UIColor colorWithWhite:0 alpha:0.45];
    self.pickerLayer.hidden = YES;

    CGFloat w = MIN(b.size.width * 0.86, 380);
    CGFloat h = MIN(b.size.height * 0.6, 460);
    UIView *card = [[UIView alloc] initWithFrame:
                    CGRectMake((b.size.width - w) / 2, (b.size.height - h) / 2 - 40, w, h)];
    card.backgroundColor = [UIColor colorWithWhite:0.13 alpha:0.98];
    card.layer.cornerRadius = 18;

    UILabel *title = [[UILabel alloc] initWithFrame:CGRectMake(16, 12, w - 32, 24)];
    title.text = @"选择要分屏的 App";
    title.textColor = [UIColor whiteColor];
    title.font = [UIFont systemFontOfSize:15 weight:UIFontWeightSemibold];
    [card addSubview:title];

    UIButton *cancel = [UIButton buttonWithType:UIButtonTypeSystem];
    [cancel setTitle:@"取消" forState:UIControlStateNormal];
    cancel.tintColor = [UIColor systemGrayColor];
    cancel.frame = CGRectMake(w - 72, 10, 56, 26);
    [cancel addTarget:self action:@selector(_hidePicker)
     forControlEvents:UIControlEventTouchUpInside];
    [card addSubview:cancel];

    self.pickerTable = [[UITableView alloc] initWithFrame:
                        CGRectMake(0, 46, w, h - 46) style:UITableViewStylePlain];
    self.pickerTable.dataSource = self;
    self.pickerTable.delegate = self;
    self.pickerTable.backgroundColor = [UIColor clearColor];
    self.pickerTable.separatorColor = [UIColor colorWithWhite:1 alpha:0.1];
    [card addSubview:self.pickerTable];

    [self.pickerLayer addSubview:card];
    [self.rootView addSubview:self.pickerLayer];
    self.rootView.pickerLayer = self.pickerLayer;
}

- (void)_pillTapped {
    [self _showPicker];
}

- (void)_showPicker {
    if (self.pickerOpen) return;
    self.pickerOpen = YES;
    // 过滤：排除 自己/SB/设置/当前主副
    NSMutableSet *exclude = [NSMutableSet setWithArray:@[
        @"com.apple.springboard", @"com.apple.Preferences"]];
    if (self.fullBid) [exclude addObject:self.fullBid];
    if (self.floatBid) [exclude addObject:self.floatBid];
    NSMutableArray *apps = [NSMutableArray array];
    for (OSAppItem *item in [OSAppSource shared].apps) {
        if (![exclude containsObject:item.bundleID]) [apps addObject:item];
    }
    self.pickerApps = apps;
    [self.pickerTable reloadData];
    self.pickerLayer.hidden = NO;
}

- (void)_hidePicker {
    self.pickerOpen = NO;
    self.pickerLayer.hidden = YES;
}

// dataSource
- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return self.pickerApps.count;
}
- (UITableViewCell *)tableView:(UITableView *)tableView
         cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"cell"];
    if (!cell) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle
                                      reuseIdentifier:@"cell"];
        cell.backgroundColor = [UIColor clearColor];
        cell.textLabel.textColor = [UIColor whiteColor];
        cell.detailTextLabel.textColor = [UIColor colorWithWhite:1 alpha:0.5];
    }
    OSAppItem *item = (NSUInteger)indexPath.row < self.pickerApps.count
        ? self.pickerApps[indexPath.row] : nil;
    cell.textLabel.text = item.displayName ?: @"";
    cell.detailTextLabel.text = item.bundleID;
    UIImage *icon = [OSRuntime iconForBundleID:item.bundleID];
    cell.imageView.image = icon ?: [UIImage systemImageNamed:@"app"];
    return cell;
}
- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    OSAppItem *item = (NSUInteger)indexPath.row < self.pickerApps.count
        ? self.pickerApps[indexPath.row] : nil;
    if (!item) return;
    [self _hidePicker];
    [self _startSplitWithBid:item.bundleID];
}

// ---------------------------------------------------------------------------
#pragma mark - 分屏编排

- (void)_startSplitWithBid:(NSString *)newFullBid {
    // 当前前台作为小窗，newFullBid 全屏启动
    NSString *current = [OSSceneKit frontmostAppBundleID];
    if (!current) current = self.fullBid;
    if (!current || OSStrEq(current, newFullBid)) {
        OSLogF(@"[Split] 无法确定主/副：cur=%@ new=%@", current, newFullBid);
        return;
    }

    self.fullBid = newFullBid;
    self.floatBid = current;

    // 原前台 app 将退后台：保活它（防挂起），随后它的小窗画面由 scene host 呈现
    [OSSceneKit startKeepAliveForBundleID:current];

    OSLogF(@"[Split] 启动全屏 %@，%@ 转小窗", newFullBid, current);
    [OSRuntime launchAppWithBundleID:newFullBid];

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.8 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        [self _mountFloatForBid:self.floatBid];
    });
}

/// 点小窗：主副互换
- (void)_floatTapped {
    if (!self.floatBid || !self.fullBid) return;
    NSString *oldFull = self.fullBid;
    NSString *oldFloat = self.floatBid;

    // 浮窗 app 变全屏；原全屏 app 转小窗并保活
    [OSSceneKit stopKeepAliveForBundleID:oldFloat];
    self.fullBid = oldFloat;
    self.floatBid = oldFull;
    [OSSceneKit startKeepAliveForBundleID:oldFull];

    OSLogF(@"[Split] 切换：%@ 全屏，%@ 转小窗", oldFloat, oldFull);
    [OSRuntime launchAppWithBundleID:oldFloat];

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.8 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        [self _mountFloatForBid:self.floatBid];
    });
}

- (void)_closeSplit {
    if (self.floatBid) {
        [OSSceneKit stopKeepAliveForBundleID:self.floatBid];
    }
    self.floatBid = nil;
    self.fullBid = nil;
    [self _removeFloat];
    [self _layoutOverlayControls];
    OSLogF(@"[Split] 分屏结束");
}

// ---------------------------------------------------------------------------
#pragma mark - 小窗

- (void)_mountFloatForBid:(NSString *)bid {
    if (!bid.length) return;
    [self _removeFloat];

    CGRect f = OSFloatDefaultFrame([OSSceneKit screenBounds]);
    UIView *host = [OSSceneKit layerHostViewForBundleID:bid frame:f];
    if (!host) {
        OSLogF(@"[Split] 小窗挂载失败：无 scene 画面 (%@)——真实渲染能力待真机确认", bid);
        return;
    }
    host.tag = 0x5A10; // "Z"
    self.floatView = host;
    self.rootView.floatView = host;
    [self.rootView addSubview:host];

    // 拖动
    UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc]
                                   initWithTarget:self action:@selector(_floatPanned:)];
    [host addGestureRecognizer:pan];
    // 点按切主副
    UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc]
                                   initWithTarget:self action:@selector(_floatTapped)];
    [host addGestureRecognizer:tap];
    [tap requireGestureRecognizerToFail:pan];

    [self _layoutOverlayControls];
    OSLogF(@"[Split] 小窗已挂载: %@", bid);
}

- (void)_removeFloat {
    if (self.floatView) {
        [self.floatView removeFromSuperview];
        self.floatView = nil;
        self.rootView.floatView = nil;
    }
}

- (void)_floatPanned:(UIPanGestureRecognizer *)g {
    UIView *v = g.view;
    if (!v) return;
    if (g.state == UIGestureRecognizerStateBegan ||
        g.state == UIGestureRecognizerStateChanged) {
        CGPoint t = [g translationInView:v.superview];
        v.center = CGPointMake(v.center.x + t.x, v.center.y + t.y);
        [g setTranslation:CGPointZero inView:v.superview];
    }
}

@end
