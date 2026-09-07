//
//  OSPasteHistory.m
//
//  跨进程剪贴板文本历史。
//  权威存储：命名剪贴板（pasteboard 服务全局可用，App 沙盒不拦截写入）。
//  附加存储：SpringBoard 进程（无沙盒限制）会把最新数据镜像到
//            /var/mobile/Library/Preferences/com.onestep.ios.history.plist，
//            重启后若命名剪贴板为空则从文件恢复。
//  写文件失败（普通 App 沙盒内）自动忽略，不影响主流程。
//

#import "OSPasteHistory.h"
#import "OSCommon.h"

// 序列化工具（命名剪贴板值必须是 plist 兼容对象，走 NSKeyedArchiver）
static NSData *OSHistoryArchive(NSArray *items) {
    if (@available(iOS 11.0, *)) {
        NSError *err = nil;
        NSData *d = [NSKeyedArchiver archivedDataWithRootObject:items
                                          requiringSecureCoding:NO
                                                          error:&err];
        return err ? nil : d;
    }
    return [NSKeyedArchiver archivedDataWithRootObject:items];
}

static NSArray *OSHistoryUnarchive(NSData *data) {
    if (!data.length) return nil;
    NSError *err = nil;
    id obj = [NSKeyedUnarchiver unarchiveTopLevelObjectWithData:data error:&err];
    if (err || ![obj isKindOfClass:NSArray.class]) return nil;
    return obj;
}

@interface OSPasteHistory ()
@property (nonatomic, strong, readwrite) NSArray<NSDictionary *> *items;
@end

@implementation OSPasteHistory

+ (instancetype)shared {
    static OSPasteHistory *s = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        s = [[OSPasteHistory alloc] init];
    });
    return s;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _items = [self _readFromPasteboard] ?: [self _readFromFile] ?: @[];
        // 若启动时命名板为空但从文件恢复了，补写回命名板
        if (![self _readFromPasteboard] && _items.count) {
            [self _writeToPasteboard:_items];
        }
    }
    return self;
}

// ---------------------------------------------------------------------------
#pragma mark - 读写

- (NSArray *)_readFromPasteboard {
    UIPasteboard *pb = [UIPasteboard pasteboardWithName:OSHistoryPasteboardName
                                                 create:NO];
    if (!pb) return nil;
    NSData *data = [pb dataForPasteboardType:OSHistoryUTI];
    return OSHistoryUnarchive(data);
}

- (void)_writeToPasteboard:(NSArray *)items {
    UIPasteboard *pb = [UIPasteboard pasteboardWithName:OSHistoryPasteboardName
                                                 create:YES];
    NSData *data = OSHistoryArchive(items);
    if (data) {
        pb.items = @[ @{ OSHistoryUTI : data } ];
    }
}

- (NSArray *)_readFromFile {
    NSDictionary *dict = [NSDictionary dictionaryWithContentsOfFile:OSHistoryPath];
    NSArray *arr = dict[OSHistoryKeyItems];
    return [arr isKindOfClass:NSArray.class] ? arr : nil;
}

// 镜像到文件：普通 App 沙盒内会失败，忽略即可（由 SB 进程成功落盘）
- (void)_mirrorToFile:(NSArray *)items {
    NSDictionary *payload = @{ OSHistoryKeyItems : items };
    [payload writeToFile:OSHistoryPath atomically:YES];
}

// ---------------------------------------------------------------------------
#pragma mark - 对外接口

- (NSArray<NSDictionary *> *)items {
    return _items;
}

- (void)addText:(NSString *)text {
    if (text.length == 0) return;
    NSString *trimmed = [text stringByTrimmingCharactersInSet:
                         NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (trimmed.length == 0) return;

    NSArray *base = [self _readFromPasteboard];
    if (!base) base = _items;

    NSMutableArray *newItems = [NSMutableArray arrayWithObject:@{
        OSHistoryKeyText : trimmed,
        OSHistoryKeyDate : [NSDate date],
    }];
    for (NSDictionary *it in base) {
        NSString *t = it[OSHistoryKeyText];
        if ([t isKindOfClass:NSString.class] && OSStrEq(t, trimmed)) continue;
        [newItems addObject:it];
        if (newItems.count >= OSMaxClipboardHistory()) break;
    }

    _items = newItems;
    [self _writeToPasteboard:newItems];
    [self _mirrorToFile:newItems];

    if (self.onChange) {
        dispatch_async(dispatch_get_main_queue(), ^{
            if (self.onChange) self.onChange();
        });
    }
}

- (void)clear {
    _items = @[];
    [self _writeToPasteboard:@[]];
    [self _mirrorToFile:@[]];
}

- (void)reload {
    NSArray *fresh = [self _readFromPasteboard];
    if (!fresh) fresh = [self _readFromFile];
    dispatch_async(dispatch_get_main_queue(), ^{
        self.items = fresh ?: @[];
        // 给持久化一次机会（若命名板才是最新而文件滞后）
        if (self.items.count) [self _mirrorToFile:self.items];
        if (self.onChange) self.onChange();
    });
}

@end
