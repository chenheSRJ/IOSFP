//
//  OneStepUI.xm  ——  SpringBoard 进程注入入口（v0.2）
//
//  职责：
//   1. SpringBoard 完全就绪后（延迟、非启动早期）拉起 OSUIManager
//
//  v0.2 变更：移除 UIPasteboard hook —— 该 hook 在 SpringBoard 启动早期
//  即被安装，叠加 OneStepPaster 曾对同一方法的重复 hook，是白苹果循环的
//  最大嫌疑；剪贴板历史改由 Paster（白名单 App 进程）上报。
//
//  filter：OneStepUI.plist（仅 com.apple.springboard）
//

#import <UIKit/UIKit.h>
#import "OSUIManager.h"

// ---------------------------------------------------------------------------
#pragma mark - 启动（保守策略）

static BOOL g_launchScheduled = NO;

static void OSScheduleStart(void) {
    if (g_launchScheduled) return;
    g_launchScheduled = YES;

    // SpringBoard 启动 2.5s 后再拉起 UI，避开早期贴靠/场景初始化窗口
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                 (int64_t)(2.5 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        @try {
            [[OSUIManager shared] start];
        } @catch (NSException *e) {
            NSLog(@"[OneStep] 启动异常（已安全忽略）: %@", e);
        }
    });
}

%hook SpringBoard

- (void)applicationDidFinishLaunching:(id)application {
    %orig;
    OSScheduleStart();
}

%end

%ctor {
    // 兜底：万一 hook 未命中，4s 后补启动（幂等，不会重复创建窗口）
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                 (int64_t)(4.0 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        @try {
            [[OSUIManager shared] start];
        } @catch (NSException *e) {
            NSLog(@"[OneStep] 兜底启动异常（已安全忽略）: %@", e);
        }
    });
}
