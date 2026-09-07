//
//  OSAppSource.h
//  已安装 App 枚举数据源
//

#import <Foundation/Foundation.h>

@class OSAppItem;

NS_ASSUME_NONNULL_BEGIN

@interface OSAppSource : NSObject

+ (instancetype)shared;

/// 已排序应用列表（固定优先 → 显示名）；图标请按需取 OSRuntime.iconForBundleID:
@property (nonatomic, readonly) NSArray<OSAppItem *> *apps;

/// 重新枚举（安装/卸载后调用）
- (void)refresh;

@end

NS_ASSUME_NONNULL_END
