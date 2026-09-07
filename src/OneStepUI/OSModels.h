//
//  OSModels.h  ——  OneStep Split 数据模型（纯值对象）
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// 应用条目（选择器/列表用）
@interface OSAppItem : NSObject
@property (nonatomic, copy) NSString *bundleID;
@property (nonatomic, copy) NSString *displayName;
@property (nonatomic, assign) BOOL pinned;
@end

NS_ASSUME_NONNULL_END
