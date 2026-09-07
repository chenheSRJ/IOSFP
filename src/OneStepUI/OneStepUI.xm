//
//  OneStepUI.xm  ——  SpringBoard 进程注入入口
//
//  职责：
//   1. SpringBoard 启动完成后拉起 OSUIManager
//   2. Hook UIPasteboard 写路径：桌面进程内发生的拷贝也进历史
//
//  filter：OneStepUI.plist（仅 com.apple.springboard）
//

#import <UIKit/UIKit.h>
#import "OSUIManager.h"
#import "OSPasteHistory.h"
#import "OSCommon.h"

// ---------------------------------------------------------------------------
#pragma mark - 剪贴板写记录（本进程内）

static void OSRecordClipboardIfChanged(UIPasteboard *pb) {
    if (pb != [UIPasteboard generalPasteboard]) return; // 只关心系统剪贴板
    NSString *s = pb.string;
    if (s.length > 0) {
        [[OSPasteHistory shared] addText:s];
    }
}

%hook UIPasteboard

- (void)setItems:(NSArray *)items options:(NSDictionary *)options {
    %orig;
    OSRecordClipboardIfChanged(self);
}
- (void)setItems:(NSArray *)items {
    %orig;
    OSRecordClipboardIfChanged(self);
}
- (void)setObjects:(NSArray *)objects options:(NSDictionary *)options {
    %orig;
    OSRecordClipboardIfChanged(self);
}
- (void)setObjects:(NSArray *)objects {
    %orig;
    OSRecordClipboardIfChanged(self);
}
- (void)setString:(NSString *)string {
    %orig;
    OSRecordClipboardIfChanged(self);
}

%end

// ---------------------------------------------------------------------------
#pragma mark - 启动

%hook SpringBoard

- (void)applicationDidFinishLaunching:(id)application {
    %orig;
    dispatch_async(dispatch_get_main_queue(), ^{
        [[OSUIManager shared] start];
    });
}

%end

%ctor {
    // 兜底：万一上面 hook 时机太晚/未命中，1.5s 后补启动
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                 (int64_t)(1.5 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        if (![OSUIManager shared].isStarted) {
            [[OSUIManager shared] start];
        }
    });
}
