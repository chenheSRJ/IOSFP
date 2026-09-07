//
//  OSModels.m
//  模型值对象 + 快捷动作清单
//

#import "OSModels.h"

@implementation OSAppItem
@end

@implementation OSClipItem
@end

@implementation OSPhotoItem
@end

@implementation OSDragPayload
@end

@implementation OSActionItem

+ (NSArray<OSActionItem *> *)allActions {
    OSActionItem *search = [OSActionItem new];
    search.kind = OSActionKindSearch;
    search.title = @"搜索";
    search.symbolName = @"magnifyingglass";

    OSActionItem *share = [OSActionItem new];
    share.kind = OSActionKindShare;
    share.title = @"分享";
    share.symbolName = @"square.and.arrow.up";

    OSActionItem *mail = [OSActionItem new];
    mail.kind = OSActionKindMail;
    mail.title = @"邮件";
    mail.symbolName = @"envelope";

    return @[ search, share, mail ];
}

@end
