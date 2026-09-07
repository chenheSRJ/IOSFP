//
//  OSCommon.h  ——  OneStep Split (v0.3) 共享常量与内联工具
//
//  v0.3 起 OneStep 从「拖放分享」重构为「iPhone 分屏」插件。
//

#ifndef OSCommon_h
#define OSCommon_h

#import <UIKit/UIKit.h>

// ============================================================================
// 日志
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
// 偏好（com.onestep.ios）
// ============================================================================
static NSString * const OSDefaultsSuite = @"com.onestep.ios";

static NSString * const OSKeyEnabled        = @"Enabled";           // 总开关
static NSString * const OSKeyPinnedBundleIDs = @"PinnedBundleIDs";  // 浮窗快捷 App
static NSString * const OSKeySnapMode       = @"SnapMode";          // 小窗贴边（预留）
static NSString * const OSKeyFloatsCount    = @"FloatsCount";       // 浮窗数量 1/2（P1）

static inline NSUserDefaults *OSPrefs(void) {
    return [[NSUserDefaults alloc] initWithSuiteName:OSDefaultsSuite];
}

static inline BOOL OSEnabled(void) {
    NSNumber *v = [OSPrefs() objectForKey:OSKeyEnabled];
    return v ? [v boolValue] : YES;
}

static inline NSArray<NSString *> *OSPinnedBundleIDs(void) {
    NSArray *a = [OSPrefs() objectForKey:OSKeyPinnedBundleIDs];
    return [a isKindOfClass:NSArray.class] ? a : @[];
}

static inline BOOL OSStrEq(NSString *a, NSString *b) {
    return (a == nil && b == nil) || [a isEqualToString:b];
}

// 小窗默认几何（以屏幕尺寸归一）
static inline CGRect OSFloatDefaultFrame(CGRect screen) {
    CGFloat w = screen.size.width * 0.42;
    CGFloat h = w * 2.0;
    if (h > screen.size.height * 0.6) h = screen.size.height * 0.6;
    CGFloat x = screen.size.width - w - 8;
    CGFloat y = screen.size.height * 0.30;
    return CGRectMake(x, y, w, h);
}

#endif /* OSCommon_h */
