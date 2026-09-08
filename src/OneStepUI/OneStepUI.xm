//
//  OneStepUI.xm  ——  SpringBoard 注入入口（v0.3.2 探针版）
//
//  职责：SpringBoard 就绪后拉起 OSSplitManager。
//  探针：所有关键路径写文件日志 /var/mobile/onestep.log（cat 即可）。
//  触发：%hook applicationDidFinishLaunching + UIApplication 通知 + ctor 兜底轮询。
//

#import <UIKit/UIKit.h>
#import "OSSplitManager.h"
#import "OSDiag.h"

static BOOL g_scheduled = NO;

static void OSScheduleStart(void) {
    if (g_scheduled) return;
    g_scheduled = YES;
    OSLogF(@"入口: 调度启动 (delay 2.5s)");
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                 (int64_t)(2.5 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        OSLogF(@"入口: 延迟启动触发");
        @try {
            [[OSSplitManager shared] start];
        } @catch (NSException *e) {
            OSLogF(@"入口: 启动异常（忽略）%@", e);
        }
    });
}

static void OSObserveLaunchNotification(void) {
    // UIApplicationDidFinishLaunchingNotification 兜底（不依赖 hook 命中）
    [[NSNotificationCenter defaultCenter]
        addObserverForName:UIApplicationDidFinishLaunchingNotification
                    object:nil queue:[NSOperationQueue mainQueue]
                usingBlock:^(NSNotification *note) {
                    OSLogF(@"入口: 收到 didFinishLaunching 通知");
                    OSScheduleStart();
                }];
}

%hook SpringBoard

- (void)applicationDidFinishLaunching:(id)application {
    %orig;
    OSLogF(@"入口: hook applicationDidFinishLaunching 命中");
    OSScheduleStart();
}

%end

%ctor {
    OSLogF(@"===== dylib 已加载 (ctor) pid=%d =====",
           (int)getpid());
    OSObserveLaunchNotification();
    OSScheduleStart();
}
