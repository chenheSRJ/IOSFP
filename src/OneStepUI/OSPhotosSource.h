//
//  OSPhotosSource.h
//  最近图片数据源（内部处理相册授权联动）
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface OSPhotosSource : NSObject

+ (instancetype)shared;

/// 最近图片 asset 数组（新→旧，元素为运行时 PHAsset 对象）
@property (nonatomic, readonly) NSArray<id> *assets;

/// 权限状态（0 未决定 1 受限 2 拒绝 3 允许 4 仅部分；-1 不支持）
@property (nonatomic, readonly) NSInteger authStatus;

/// 数据变化回调（主线程）
@property (nonatomic, copy, nullable) void (^onChange)(void);

/// 拉取最新（未授权时会自动弹系统授权框；拒绝时置空）
- (void)refresh;

@end

NS_ASSUME_NONNULL_END
