//
//  OSActionPlanner.m
//  实现：见头文件注释。
//
//  拖放直达的关键路径：
//    1) 保存 general 剪贴板现状（用于 Paster 粘贴成功后的还原）
//    2) 把内容写入 general 剪贴板（供目标 App 的粘贴操作消费）
//    3) 把结构化 payload 序列化写入命名剪贴板（Paster 据此判断目标与还原）
//    4) 拉起目标 App；随后广播 Darwin 通知，Paster 在目标进程内执行粘贴
//

#import "OSActionPlanner.h"
#import "OSModels.h"
#import "OSCommon.h"
#import "OSRuntime.h"

static NSString *const OSUTIPlainText = @"public.utf8-plain-text";

@implementation OSActionPlanner

+ (instancetype)shared {
    static OSActionPlanner *s = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        s = [[OSActionPlanner alloc] init];
    });
    return s;
}

// ============================================================================
// 内部工具
// ============================================================================

/// payload 字典 → 序列化 NSData
static NSData *OSArchivedPayload(NSDictionary *dict) {
    if (!dict) return nil;
    if (@available(iOS 11.0, *)) {
        NSError *err = nil;
        NSData *d = [NSKeyedArchiver archivedDataWithRootObject:dict
                                          requiringSecureCoding:NO
                                                          error:&err];
        if (!err) return d;
        OSLog(@"payload 归档失败: %@", err);
        return nil;
    }
    return [NSKeyedArchiver archivedDataWithRootObject:dict];
}

/// 写命名剪贴板（清空旧的再写，避免脏数据残留）
/// item0 = 归档 payload；item1 = 原剪贴板内容（原样，不归档）
static void OSWritePayloadPasteboard(NSDictionary *payload, NSArray *originalItems) {
    UIPasteboard *pb = [UIPasteboard pasteboardWithName:OSPayloadPasteboardName create:YES];
    if (!payload) {
        pb.items = @[];
        return;
    }
    NSData *data = OSArchivedPayload(payload);
    if (data) {
        pb.items = @[
            @{ OSPayloadUTI : data },
            @{ OSOriginalUTI : (originalItems ?: @[]) },
        ];
    }
}

/// 组装载荷字典（payload 只含可归档内容，不含原剪贴板快照）
static NSDictionary *OSMakePayloadDict(OSDragPayload *p, NSString *targetBID) {
    NSMutableDictionary *d = [NSMutableDictionary dictionary];
    d[OSPlVersion] = @1;
    d[OSPlKind] = (p.kind == OSItemKindImage) ? @"image" : @"text";
    if (p.text) d[OSPlText] = p.text;
    if (p.imageData) d[OSPlImageData] = p.imageData;
    if (p.imageUTI) d[OSPlImageUTI] = p.imageUTI;
    d[OSPlTargetBundleID] = targetBID ?: @"";
    d[OSPlSourceApp] = p.sourceTitle ?: @"";
    d[OSPlTimestamp] = @([NSDate date].timeIntervalSince1970);
    return d;
}

/// 把载荷内容写入 general 剪贴板
static void OSWriteGeneralClipboard(OSDragPayload *p) {
    UIPasteboard *gp = [UIPasteboard generalPasteboard];
    if (p.kind == OSItemKindImage && p.imageData.length) {
        NSString *uti = p.imageUTI.length ? p.imageUTI : (NSString *)@"public.png";
        gp.items = @[ @{ uti : p.imageData } ];
    } else if (p.text.length) {
        gp.items = @[ @{ OSUTIPlainText : p.text } ];
    }
}

// ============================================================================
// 对外接口
// ============================================================================

/// 图片载荷若数据未就绪，先经 imageProvider 异步补齐再回调；文本立即回调。
- (void)_withReadyPayload:(OSDragPayload *)payload
               completion:(void (^)(OSDragPayload *ready, BOOL ok))completion {
    if (!payload) {
        if (completion) completion(nil, NO);
        return;
    }
    if (payload.kind == OSItemKindImage && payload.imageData.length == 0
        && payload.imageProvider) {
        payload.imageProvider(^(NSData *data) {
            if (data.length) payload.imageData = data;
            if (completion) completion(payload, data.length > 0);
        });
        return;
    }
    BOOL ok = YES;
    if (payload.kind == OSItemKindImage) ok = payload.imageData.length > 0;
    if (completion) completion(payload, ok);
}

- (void)deliverPayload:(OSDragPayload *)payload toAppBundleID:(NSString *)bundleID
               appName:(NSString *)appName {
    if (!payload || bundleID.length == 0) return;

    [self _withReadyPayload:payload completion:^(OSDragPayload *ready, BOOL ok) {
        if (!ok) {
            OSLog(@"OneStep deliver 失败：内容不可用 (%@)", appName ?: bundleID);
            return;
        }
        // 先快照用户原剪贴板，再覆盖写入发送内容
        NSArray *originals = [UIPasteboard generalPasteboard].items;
        OSWriteGeneralClipboard(ready);
        NSDictionary *payloadDict = OSMakePayloadDict(ready, bundleID);
        OSWritePayloadPasteboard(payloadDict, originals);

        BOOL launched = [OSRuntime launchAppWithBundleID:bundleID];
        OSLog(@"OneStep deliver → %@(%@) launched=%d kind=%ld",
              appName ?: bundleID, bundleID, launched, (long)ready.kind);

        // 通知各进程：有新拖放载荷
        CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
                                             (__bridge CFStringRef)OSNotifyDragLaunched,
                                             NULL, NULL, YES);
    }];
}

- (void)deliverPayload:(OSDragPayload *)payload toAction:(OSActionItem *)action {
    if (!payload) return;
    switch (action.kind) {
        case OSActionKindSearch: {
            if (payload.kind == OSItemKindText && payload.text.length) {
                NSString *tmpl = [OSPrefs() objectForKey:OSKeySearchTemplate];
                if (![tmpl isKindOfClass:NSString.class] || tmpl.length == 0) {
                    tmpl = @"https://www.bing.com/search?q=%@";
                }
                NSCharacterSet *set = [NSCharacterSet characterSetWithCharactersInString:
                                       @"!*'();:@&=+$,/?%#[]"];
                NSString *q = [payload.text stringByAddingPercentEncodingWithAllowedCharacters:
                               [set invertedSet]];
                NSString *urlStr = [NSString stringWithFormat:tmpl, q];
                NSURL *url = [NSURL URLWithString:urlStr];
                if (url) [OSRuntime openURL:url];
            }
            break;
        }
        case OSActionKindMail: {
            if (payload.kind == OSItemKindText && payload.text.length) {
                NSCharacterSet *set = [NSCharacterSet characterSetWithCharactersInString:
                                       @"!*'();:@&=+$,/?%#[]"];
                NSString *body = [payload.text stringByAddingPercentEncodingWithAllowedCharacters:
                                  [set invertedSet]];
                NSURL *url = [NSURL URLWithString:
                              [NSString stringWithFormat:@"mailto:?body=%@", body]];
                if (url) [OSRuntime openURL:url];
            }
            break;
        }
        case OSActionKindShare: {
            // 用系统分享面板（可在任何进程弹）
            UIViewController *presenter = self.presenter;
            if (!presenter) break;
            [self _withReadyPayload:payload completion:^(OSDragPayload *ready, BOOL ok) {
                if (!ok || !self.presenter) return;
                NSArray *items = nil;
                if (ready.kind == OSItemKindImage && ready.imageData.length) {
                    UIImage *img = [UIImage imageWithData:ready.imageData];
                    items = img ? @[ img ] : nil;
                } else if (ready.text.length) {
                    items = @[ ready.text ];
                }
                if (!items.count) return;

                UIViewController *pv = self.presenter;
                UIActivityViewController *ac =
                    [[UIActivityViewController alloc] initWithActivityItems:items
                                                      applicationActivities:nil];
                ac.popoverPresentationController.sourceView = pv.view;

                UIWindow *w = pv.view.window;
                UIWindow *oldKey = nil;
                if (w && !w.isKeyWindow) {
                    oldKey = [UIApplication sharedApplication].keyWindow;
                    [w makeKeyWindow];
                }
                [pv presentViewController:ac animated:YES completion:^{
                    if (oldKey) [oldKey makeKeyWindow];
                }];
            }];
            break;
        }
    }
}

- (void)copyTextToClipboard:(NSString *)text {
    if (text.length == 0) return;
    UIPasteboard *gp = [UIPasteboard generalPasteboard];
    gp.items = @[ @{ OSUTIPlainText : text } ];
    OSLog(@"OneStep 复制回剪贴板：%@", text);
}

@end
