//
//  OneStepUI.xm  ——  SpringBoard 注入入口（v0.3 分屏）
//
//  职责：SpringBoard 完全就绪后（延迟、非启动早期）拉起 OSSplitManager。
//  安全策略沿袭 v0.2：延迟启动、@try 保护、幂等——不因注入代码拖垮 SB。
//
//  filter：OneStepUI.plist（仅 com.apple.springboard）
//

#import <UIKit/UIKit.h>
#import "OSSplitManager.h"

static BOOL g_scheduled = NO;

static void OSScheduleStart(void) {
    if (g_scheduled) return;
    g_scheduled = YES;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                 (int64_t)(2.5 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        @try {
            [[OSSplitManager shared] start];
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
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                 (int64_t)(4.0 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        @try {
            [[OSSplitManager shared] start];
        } @catch (NSException *e) {
            NSLog(@"[OneStep] 兜底启动异常（已安全忽略）: %@", e);
        }
    });
}
