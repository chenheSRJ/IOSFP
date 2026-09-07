//
//  OSCommon.h
//  OneStep for iOS —— 共享常量 / 跨进程协议
//
//  被 OneStepUI（SpringBoard）与 OneStepPaster（各 App 进程）共同引用。
//  只放宏 / 枚举 / 内联工具，避免重复编译成本。
//

#ifndef OSCommon_h
#define OSCommon_h

#import <UIKit/UIKit.h>

// ============================================================================
// 日志（发布版保留，频率很低；排查问题主要靠它）
// ============================================================================
#ifdef ONESTEP_VERBOSE
#define OSLog(fmt, ...) NSLog(@"[OneStep] " fmt, ##__VA_ARGS__)
#else
#define OSLog(fmt, ...) do { if (OSVerboseEnabled()) NSLog(@"[OneStep] " fmt, ##__VA_ARGS__); } while (0)
#endif

static inline BOOL OSVerboseEnabled(void) {
    static BOOL cached = NO;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        cached = [[[NSUserDefaults standardUserDefaults] objectForKey:@"OneStepVerbose"] boolValue];
    });
    return cached;
}

// ============================================================================
// 偏好（与 layout/var/mobile/Library/Preferences/com.onestep.ios.plist 对应）
// 注：NSUserDefaults initWithSuiteName 的域根即该 plist，Relaxin/rootless 下
//     偏好文件同样落在 /var/mobile/Library/Preferences/（不走 /var/jb）。
// ============================================================================
static NSString * const OSDefaultsSuite = @"com.onestep.ios";

// 键名
static NSString * const OSKeyEnabled                 = @"Enabled";
static NSString * const OSKeyTrayCollapsedByDefault  = @"TrayCollapsedByDefault";
static NSString * const OSKeyMaxClipboardHistory     = @"MaxClipboardHistory";
static NSString * const OSKeyMaxRecentPhotos         = @"MaxRecentPhotos";
static NSString * const OSKeyAutoPasteDelay          = @"AutoPasteDelay";
static NSString * const OSKeyRestoreClipboardAfterPaste = @"RestoreClipboardAfterPaste";
static NSString * const OSKeyPinnedBundleIDs         = @"PinnedBundleIDs";
static NSString * const OSKeySearchTemplate          = @"SearchTemplate"; // 拖文本→搜索 的 URL 模板，含 %@

static inline NSUserDefaults *OSPrefs(void) {
    return [[NSUserDefaults alloc] initWithSuiteName:OSDefaultsSuite];
}
static inline BOOL OSEnabled(void) {
    NSNumber *v = [OSPrefs() objectForKey:OSKeyEnabled];
    return v ? [v boolValue] : YES; // 默认开启
}
static inline NSInteger OSMaxClipboardHistory(void) {
    NSNumber *v = [OSPrefs() objectForKey:OSKeyMaxClipboardHistory];
    NSInteger n = v ? [v integerValue] : 12;
    return MAX(1, MIN(n, 50));
}
static inline NSInteger OSMaxRecentPhotos(void) {
    NSNumber *v = [OSPrefs() objectForKey:OSKeyMaxRecentPhotos];
    NSInteger n = v ? [v integerValue] : 9;
    return MAX(0, MIN(n, 24));
}
static inline NSArray<NSString *> *OSPinnedBundleIDs(void) {
    NSArray *a = [OSPrefs() objectForKey:OSKeyPinnedBundleIDs];
    return [a isKindOfClass:NSArray.class] ? a : @[];
}

// ============================================================================
// 跨进程 Darwin 通知（CFNotificationCenter 只能传名字，不能传 userInfo，
// 负载一律通过「命名剪贴板」或文件传递，见下）
// ============================================================================
static NSString * const OSNotifyDragLaunched     = @"com.onestep.ios.event.drag-launched";     // SB → 各 App
static NSString * const OSNotifyPasteFinished    = @"com.onestep.ios.event.paste-finished";    // 各 App → SB
static NSString * const OSNotifyClipboardChanged = @"com.onestep.ios.event.clipboard-changed"; // 各 App → SB

// ============================================================================
// 命名剪贴板
//  - Payload 板：SB 发起拖放时写入；目标 App 进程读取（跨进程传二进制/文本）。
// 命名剪贴板位于 pasteboard 服务，任意进程可读写，不会污染用户 general 剪贴板。
// ============================================================================
static NSString * const OSPayloadPasteboardName = @"com.onestep.ios.payload";
// 写入命名剪贴板时使用的 UTI（值为 NSKeyedArchiver 序列化后的 payload dict）
static NSString * const OSPayloadUTI = @"com.onestep.ios.payload";
// 命名剪贴板第二 item：用户「拖放前」的 general 剪贴板内容（原样对象数组，
// 可能含 UIImage/UIColor 等非 plist 类型，故不能走 NSKeyedArchiver，
// 作为 pasteboard item 原样存放，粘贴成功后由 Paster 写回还原）
static NSString * const OSOriginalUTI = @"com.onestep.ios.original-items";

// ============================================================================
// 剪贴板历史（跨进程）：
//  权威存储 = 命名剪贴板（pasteboard 服务全局可用，App 沙盒不拦截）；
//  SpringBoard（无沙盒限制）额外镜像一份到文件，供重启后恢复。
// ============================================================================
static NSString * const OSHistoryPasteboardName = @"com.onestep.ios.clipboard-history";
static NSString * const OSHistoryUTI = @"com.onestep.ios.history";

// Payload dict 键
static NSString * const OSPlVersion          = @"v";               // NSNumber int
static NSString * const OSPlKind             = @"kind";            // NSString: "text" | "image"
static NSString * const OSPlText             = @"text";            // NSString (kind == text)
static NSString * const OSPlImageData        = @"imageData";       // NSData   (kind == image)
static NSString * const OSPlImageUTI         = @"imageUTI";        // NSString，默认 public.png
static NSString * const OSPlTargetBundleID   = @"targetBundleID";  // 目标 App，Paster 用于判断是否自己
static NSString * const OSPlSourceApp        = @"sourceApp";       // 来源说明（如「剪贴板」「相册」）
static NSString * const OSPlOriginalItems    = @"originalItems";   // 拖放前 general 剪贴板 items（粘贴成功后还原）
static NSString * const OSPlTimestamp        = @"ts";              // NSNumber double

typedef NS_ENUM(NSInteger, OSItemKind) {
    OSItemKindText = 0,
    OSItemKindImage = 1,
};

// ============================================================================
// 历史记录文件镜像（仅 SpringBoard 进程可写，供重启恢复；见 OSPasteHistory.m）
// ============================================================================
static NSString * const OSHistoryPath = @"/var/mobile/Library/Preferences/com.onestep.ios.history.plist";
static NSString * const OSHistoryKeyItems = @"items"; // 数组：{text, date}，新在前
static NSString * const OSHistoryKeyText  = @"text";
static NSString * const OSHistoryKeyDate  = @"date";

// 字符串常量宏（NSString 必须用字面量比较时避免 ==）
static inline BOOL OSStrEq(NSString *a, NSString *b) {
    return (a == nil && b == nil) || [a isEqualToString:b];
}

#endif /* OSCommon_h */
