//
//  OSPasteHistory.h
//  剪贴板文本历史存储（跨进程共享：各 App 写、SpringBoard 读）
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface OSPasteHistory : NSObject

+ (instancetype)shared;

/// 现有历史（新→旧）。每项为 {text: NSString, date: NSDate}。
@property (nonatomic, readonly) NSArray<NSDictionary *> *items;

/// 追加一条文本历史（自动去重、按偏好上限裁剪、落盘）。
- (void)addText:(NSString *)text;

/// 从磁盘重新加载（其他进程可能已写入）。
- (void)reload;

/// 清空全部历史。
- (void)clear;

/// 数据变化（主线程回调），UI 侧订阅刷新。
@property (nonatomic, copy, nullable) void (^onChange)(void);

@end

NS_ASSUME_NONNULL_END
