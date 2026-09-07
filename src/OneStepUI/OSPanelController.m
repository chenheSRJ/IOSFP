//
//  OSPanelController.m
//  主面板实现：布局全部手排（layoutSubviews 内按安全区重算），
//  不依赖第三方库；图标/缩略图惰性异步加载。
//

#import "OSPanelController.h"
#import "OSModels.h"
#import "OSAppSource.h"
#import "OSPhotosSource.h"
#import "OSPasteHistory.h"
#import "OSRuntime.h"
#import "OSCommon.h"
#import <QuartzCore/QuartzCore.h>

// ---------------------------------------------------------------------------
#pragma mark - 小组件

/// 剪贴板历史行（支持点击=复制、长按=拖拽）
@interface OSClipRowView : UIButton
@property (nonatomic, copy) NSString *clipText;
@property (nonatomic, strong) UILabel *titleLabel;
@end

@implementation OSClipRowView
- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        self.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.12];
        self.layer.cornerRadius = 8;
        self.clipsToBounds = YES;

        _titleLabel = [[UILabel alloc] initWithFrame:CGRectZero];
        _titleLabel.font = [UIFont systemFontOfSize:12 weight:UIFontWeightRegular];
        _titleLabel.textColor = [UIColor colorWithWhite:1 alpha:0.92];
        _titleLabel.lineBreakMode = NSLineBreakByTruncatingTail;
        _titleLabel.userInteractionEnabled = NO;
        [self addSubview:_titleLabel];
    }
    return self;
}
- (void)layoutSubviews {
    [super layoutSubviews];
    self.titleLabel.frame = CGRectInset(self.bounds, 10, 0);
}
- (void)setHighlighted:(BOOL)highlighted {
    [super setHighlighted:highlighted];
    self.backgroundColor = [UIColor colorWithWhite:1.0
                                            alpha:highlighted ? 0.30 : 0.12];
}
@end

/// 应用格子
@interface OSAppCell : UICollectionViewCell
@property (nonatomic, strong) UIImageView *iconView;
@property (nonatomic, strong) UILabel *nameLabel;
@property (nonatomic, strong) UIView *ringView;
- (void)setDropHighlighted:(BOOL)on;
@end

@implementation OSAppCell
- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        _iconView = [[UIImageView alloc] initWithFrame:CGRectZero];
        _iconView.contentMode = UIViewContentModeScaleAspectFit;
        _iconView.layer.cornerRadius = 10;
        _iconView.clipsToBounds = YES;
        [self.contentView addSubview:_iconView];

        _nameLabel = [[UILabel alloc] initWithFrame:CGRectZero];
        _nameLabel.font = [UIFont systemFontOfSize:9];
        _nameLabel.textColor = [UIColor colorWithWhite:1 alpha:0.9];
        _nameLabel.textAlignment = NSTextAlignmentCenter;
        _nameLabel.lineBreakMode = NSLineBreakByTruncatingTail;
        [self.contentView addSubview:_nameLabel];

        _ringView = [[UIView alloc] initWithFrame:CGRectZero];
        _ringView.layer.borderWidth = 2;
        _ringView.layer.borderColor = [UIColor systemTealColor].CGColor;
        _ringView.layer.cornerRadius = 12;
        _ringView.hidden = YES;
        _ringView.userInteractionEnabled = NO;
        [self.contentView addSubview:_ringView];
    }
    return self;
}
- (void)layoutSubviews {
    [super layoutSubviews];
    CGFloat iw = 46;
    _iconView.frame = CGRectMake((self.bounds.size.width - iw) / 2, 2, iw, iw);
    _nameLabel.frame = CGRectMake(0, iw + 6, self.bounds.size.width, 14);
    _ringView.frame = CGRectInset(_iconView.frame, -4, -4);
}
- (void)setDropHighlighted:(BOOL)on {
    _ringView.hidden = !on;
}
@end

/// 相册缩略格
@interface OSPhotoCell : UICollectionViewCell
@property (nonatomic, strong) UIImageView *imageView;
@end

@implementation OSPhotoCell
- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        _imageView = [[UIImageView alloc] initWithFrame:CGRectZero];
        _imageView.contentMode = UIViewContentModeScaleAspectFill;
        _imageView.clipsToBounds = YES;
        _imageView.layer.cornerRadius = 8;
        [self.contentView addSubview:_imageView];
    }
    return self;
}
- (void)layoutSubviews {
    [super layoutSubviews];
    self.imageView.frame = self.bounds;
}
@end

/// 快捷动作按钮
@interface OSActionButton : UIControl
@property (nonatomic, strong) UIImageView *iconView;
@property (nonatomic, strong) UILabel *titleLabel;
@property (nonatomic, strong) OSActionItem *action;
@end

@implementation OSActionButton
- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        _iconView = [[UIImageView alloc] initWithFrame:CGRectZero];
        _iconView.contentMode = UIViewContentModeScaleAspectFit;
        _iconView.tintColor = [UIColor colorWithWhite:1 alpha:0.95];
        [self addSubview:_iconView];
        _titleLabel = [[UILabel alloc] initWithFrame:CGRectZero];
        _titleLabel.font = [UIFont systemFontOfSize:10];
        _titleLabel.textColor = [UIColor colorWithWhite:1 alpha:0.9];
        _titleLabel.textAlignment = NSTextAlignmentCenter;
        [self addSubview:_titleLabel];
    }
    return self;
}
- (void)layoutSubviews {
    [super layoutSubviews];
    _iconView.frame = CGRectMake(0, 4, self.bounds.size.width, 18);
    _titleLabel.frame = CGRectMake(0, 24, self.bounds.size.width, 14);
}
- (void)setHighlighted:(BOOL)highlighted {
    [super setHighlighted:highlighted];
    self.alpha = highlighted ? 0.55 : 1.0;
}
@end

// ---------------------------------------------------------------------------
#pragma mark - 面板控制器

static NSString *const OSAppCellID = @"OSAppCell";
static NSString *const OSPhotoCellID = @"OSPhotoCell";
static CGFloat const OSPanelWidthRatio = 0.80f;

@interface OSPanelController () <UICollectionViewDataSource, UICollectionViewDelegate,
                                 UICollectionViewDelegateFlowLayout, UIGestureRecognizerDelegate>
@property (nonatomic, strong) UIView *handleView;
@property (nonatomic, strong) UIView *dimView;
@property (nonatomic, strong) UIVisualEffectView *panelView;
@property (nonatomic, strong) UIView *panelContent; // 面板内自绘容器（毛玻璃之上）
@property (nonatomic, strong) UILabel *titleLabel;
@property (nonatomic, strong) UIButton *closeButton;

// 顶部托盘
@property (nonatomic, strong) UIView *trayView;
@property (nonatomic, strong) UILabel *clipSectionTitle;
@property (nonatomic, strong) UIView *clipContainer; // 手动 frame 排布（不用 UIStackView，避免与手排冲突）
@property (nonatomic, strong) UILabel *photoSectionTitle;
@property (nonatomic, strong) UICollectionView *photosView;

// 应用区
@property (nonatomic, strong) UICollectionView *appsView;

// 底部快捷动作
@property (nonatomic, strong) UIView *actionRow;
@property (nonatomic, strong) NSArray<OSActionButton *> *actionButtons;

@property (nonatomic, strong) NSArray<OSClipRowView *> *clipRows;
@property (nonatomic, strong) NSArray<OSClipItem *> *displayedClips;

// 拖拽源 / 目标
@property (nonatomic, strong) OSClipRowView *activeSourceRow;
@property (nonatomic, assign) BOOL expanded;
@property (nonatomic, strong) OSAppCell *highlightedAppCell;
@property (nonatomic, strong) OSActionButton *highlightedAction;

@property (nonatomic, assign) CGFloat panelWidth;
@end

@implementation OSPanelController

- (instancetype)init {
    self = [super initWithNibName:nil bundle:nil];
    if (self) {
        _expanded = NO;
    }
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = [UIColor clearColor];

    [self _buildDimAndHandle];
    [self _buildPanel];
    [self _buildTray];
    [self _buildActions];
    [self _buildAppsCollection];
    [self _layoutAll];
}

// ---------------------------------------------------------------------------
#pragma mark - 构造

- (void)_buildDimAndHandle {
    _dimView = [[UIView alloc] initWithFrame:CGRectZero];
    _dimView.backgroundColor = [UIColor blackColor];
    _dimView.alpha = 0.0;
    _dimView.hidden = YES;
    UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc]
                                    initWithTarget:self action:@selector(_dimTapped)];
    [_dimView addGestureRecognizer:tap];
    [self.view addSubview:_dimView];

    _handleView = [[UIView alloc] initWithFrame:CGRectZero];
    _handleView.backgroundColor = [UIColor colorWithWhite:0.15 alpha:0.75];
    _handleView.layer.cornerRadius = 7;
    _handleView.layer.shadowColor = [UIColor blackColor].CGColor;
    _handleView.layer.shadowOpacity = 0.35;
    _handleView.layer.shadowRadius = 3;
    _handleView.layer.shadowOffset = CGSizeZero;
    [self.view addSubview:_handleView];

    // 把手上的竖线提示
    UIView *grip = [[UIView alloc] initWithFrame:CGRectZero];
    grip.backgroundColor = [UIColor colorWithWhite:1 alpha:0.85];
    grip.layer.cornerRadius = 2;
    grip.userInteractionEnabled = NO;
    grip.tag = 77;
    [_handleView addSubview:grip];

    UITapGestureRecognizer *handleTap = [[UITapGestureRecognizer alloc]
                                          initWithTarget:self action:@selector(_handleTapped)];
    [_handleView addGestureRecognizer:handleTap];
    UIPanGestureRecognizer *handlePan = [[UIPanGestureRecognizer alloc]
                                          initWithTarget:self action:@selector(_handlePanned:)];
    [_handleView addGestureRecognizer:handlePan];
}

- (void)_buildPanel {
    UIBlurEffect *effect = [UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemMaterialDark];
    _panelView = [[UIVisualEffectView alloc] initWithEffect:effect];
    _panelView.layer.cornerRadius = 22;
    _panelView.clipsToBounds = YES;
    [self.view addSubview:_panelView];

    _panelContent = [[UIView alloc] initWithFrame:CGRectZero];
    _panelContent.userInteractionEnabled = YES;
    [_panelView.contentView addSubview:_panelContent];

    _titleLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    _titleLabel.text = @"一步";
    _titleLabel.font = [UIFont systemFontOfSize:17 weight:UIFontWeightBold];
    _titleLabel.textColor = [UIColor colorWithWhite:1 alpha:0.95];
    [_panelContent addSubview:_titleLabel];

    UIImage *x = [UIImage systemImageNamed:@"xmark"];
    _closeButton = [UIButton buttonWithType:UIButtonTypeSystem];
    [_closeButton setImage:x forState:UIControlStateNormal];
    _closeButton.tintColor = [UIColor colorWithWhite:1 alpha:0.9];
    [_closeButton addTarget:self action:@selector(_closeTapped)
           forControlEvents:UIControlEventTouchUpInside];
    [_panelContent addSubview:_closeButton];

    // 面板边缘向左拖 = 收起
    UIPanGestureRecognizer *closePan = [[UIPanGestureRecognizer alloc]
                                         initWithTarget:self action:@selector(_panelPanned:)];
    closePan.delegate = self;
    [_panelView addGestureRecognizer:closePan];
}

- (void)_buildTray {
    _trayView = [[UIView alloc] initWithFrame:CGRectZero];
    _trayView.userInteractionEnabled = YES;
    [_panelContent addSubview:_trayView];

    _clipSectionTitle = [self _sectionLabel:@"最近剪贴板"];
    [_trayView addSubview:_clipSectionTitle];

    _clipContainer = [[UIView alloc] initWithFrame:CGRectZero];
    _clipContainer.userInteractionEnabled = YES;
    [_trayView addSubview:_clipContainer];

    _photoSectionTitle = [self _sectionLabel:@"最近图片"];
    [_trayView addSubview:_photoSectionTitle];

    UICollectionViewFlowLayout *fl = [[UICollectionViewFlowLayout alloc] init];
    fl.scrollDirection = UICollectionViewScrollDirectionHorizontal;
    fl.minimumInteritemSpacing = 6;
    fl.minimumLineSpacing = 6;
    _photosView = [[UICollectionView alloc] initWithFrame:CGRectZero
                                     collectionViewLayout:fl];
    _photosView.backgroundColor = [UIColor clearColor];
    _photosView.dataSource = self;
    _photosView.delegate = self;
    _photosView.showsHorizontalScrollIndicator = NO;
    [_photosView registerClass:OSPhotoCell.class forCellWithReuseIdentifier:OSPhotoCellID];
    [_trayView addSubview:_photosView];

    // 长按相册缩略 → 拖拽
    UILongPressGestureRecognizer *lp = [[UILongPressGestureRecognizer alloc]
                                         initWithTarget:self action:@selector(_photoLongPressed:)];
    lp.minimumPressDuration = 0.18;
    [_photosView addGestureRecognizer:lp];
}

- (void)_buildActions {
    _actionRow = [[UIView alloc] initWithFrame:CGRectZero];
    _actionRow.userInteractionEnabled = YES;
    [_panelContent addSubview:_actionRow];

    NSMutableArray *btns = [NSMutableArray array];
    for (OSActionItem *a in [OSActionItem allActions]) {
        OSActionButton *b = [[OSActionButton alloc] initWithFrame:CGRectZero];
        b.action = a;
        UIImage *sym = [UIImage systemImageNamed:a.symbolName];
        b.iconView.image = sym;
        b.titleLabel.text = a.title;
        [b addTarget:self action:@selector(_actionTapped:)
            forControlEvents:UIControlEventTouchUpInside];
        [_actionRow addSubview:b];
        [btns addObject:b];
    }
    _actionButtons = btns;
}

- (void)_buildAppsCollection {
    UICollectionViewFlowLayout *fl = [[UICollectionViewFlowLayout alloc] init];
    fl.scrollDirection = UICollectionViewScrollDirectionVertical;
    fl.minimumInteritemSpacing = 2;
    fl.minimumLineSpacing = 10;
    _appsView = [[UICollectionView alloc] initWithFrame:CGRectZero
                                   collectionViewLayout:fl];
    _appsView.backgroundColor = [UIColor clearColor];
    _appsView.dataSource = self;
    _appsView.delegate = self;
    _appsView.alwaysBounceVertical = YES;
    _appsView.showsVerticalScrollIndicator = NO;
    _appsView.keyboardDismissMode = UIScrollViewKeyboardDismissModeNone;
    [_appsView registerClass:OSAppCell.class forCellWithReuseIdentifier:OSAppCellID];
    [_panelContent addSubview:_appsView];
}

- (UILabel *)_sectionLabel:(NSString *)text {
    UILabel *l = [[UILabel alloc] initWithFrame:CGRectZero];
    l.text = text;
    l.font = [UIFont systemFontOfSize:11 weight:UIFontWeightSemibold];
    l.textColor = [UIColor colorWithWhite:1 alpha:0.55];
    return l;
}

// ---------------------------------------------------------------------------
#pragma mark - 布局

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    [self _layoutAll];
}

- (void)_layoutAll {
    CGRect b = self.view.bounds;
    if (b.size.width <= 0) return;
    CGFloat W = b.size.width;
    CGFloat H = b.size.height;
    UIEdgeInsets safe = self.view.safeAreaInsets;

    _panelWidth = MIN(330, W * OSPanelWidthRatio);
    CGFloat px = _expanded ? (W - _panelWidth) : W;

    // 遮罩：面板左侧区域
    _dimView.frame = CGRectMake(0, 0, MAX(px - 6, 0), H);

    // 把手：右缘中部
    CGFloat hw = 16, hh = 132, hy = (H - hh) / 2;
    _handleView.frame = CGRectMake(W - hw - 2, hy, hw, hh);
    UIView *grip = [_handleView viewWithTag:77];
    grip.frame = CGRectMake((hw - 4) / 2, 22, 4, hh - 44);

    // 面板
    _panelView.frame = CGRectMake(px, 0, _panelWidth, H);

    // 面板内容
    CGFloat top = safe.top + 10;
    CGFloat pad = 14;
    CGFloat cw = _panelWidth - pad * 2;
    _panelContent.frame = CGRectMake(pad, top, cw, H - top - safe.bottom - 6);

    // 标题行
    _titleLabel.frame = CGRectMake(0, 0, cw - 40, 26);
    _closeButton.frame = CGRectMake(cw - 30, 0, 30, 26);

    // 托盘
    CGFloat trayTop = 34;
    CGFloat clipRowH = 28;
    NSUInteger clipN = _displayedClips.count;
    CGFloat trayH = 26 /*剪贴板标题*/ + clipN * (clipRowH + 6)
                  + 18 /*图片标题*/ + 48 /*相册行*/ + 8;
    _trayView.frame = CGRectMake(0, trayTop, cw, trayH);

    CGFloat y = 0;
    _clipSectionTitle.frame = CGRectMake(2, y, cw, 16);
    y += 20;
    CGFloat rowH = 28;
    _clipContainer.frame = CGRectMake(0, y, cw, clipN * (rowH + 6));
    NSUInteger ri = 0;
    for (UIView *sub in _clipContainer.subviews) {
        sub.frame = CGRectMake(0, ri * (rowH + 6), cw, rowH);
        ri++;
    }
    y += _clipContainer.frame.size.height + 12;
    _photoSectionTitle.frame = CGRectMake(2, y, cw, 16);
    y += 20;
    _photosView.frame = CGRectMake(0, y, cw, 48);

    // 快捷动作行（底部）
    CGFloat arH = 42;
    _actionRow.frame = CGRectMake(0, _panelContent.bounds.size.height - arH - 6,
                                  cw, arH);
    CGFloat aw = cw / _actionButtons.count;
    for (NSUInteger i = 0; i < _actionButtons.count; i++) {
        OSActionButton *b = _actionButtons[i];
        b.frame = CGRectMake(i * aw, 0, aw, arH);
    }

    // 应用网格（夹在托盘与动作行之间）
    _appsView.frame = CGRectMake(-4, trayTop + trayH + 10, cw + 8,
                                 _panelContent.bounds.size.height
                                 - (trayTop + trayH + 10) - arH - 14);
}

// ---------------------------------------------------------------------------
#pragma mark - 数据

- (void)reloadAllData {
    [self reloadClipboardOnly];
    [self _reloadPhotos];
}

- (void)reloadClipboardOnly {
    NSArray *hist = [OSPasteHistory shared].items;
    NSMutableArray *items = [NSMutableArray array];
    NSUInteger maxN = MIN(hist.count, (NSUInteger)4);
    for (NSUInteger i = 0; i < maxN; i++) {
        NSDictionary *d = hist[i];
        if (![d isKindOfClass:NSDictionary.class]) continue;
        NSString *t = d[OSHistoryKeyText];
        if ([t isKindOfClass:NSString.class] && t.length) {
            OSClipItem *it = [OSClipItem new];
            it.text = t;
            it.date = d[OSHistoryKeyDate];
            [items addObject:it];
        }
    }
    _displayedClips = items;

    // 重建行
    for (UIView *v in _clipContainer.subviews) [v removeFromSuperview];
    NSMutableArray *rows = [NSMutableArray array];
    for (OSClipItem *it in items) {
        OSClipRowView *row = [[OSClipRowView alloc] initWithFrame:CGRectZero];
        row.clipText = it.text;
        row.titleLabel.text = it.text;

        UILongPressGestureRecognizer *lp = [[UILongPressGestureRecognizer alloc]
                                             initWithTarget:self
                                             action:@selector(_clipLongPressed:)];
        lp.minimumPressDuration = 0.18;
        [row addGestureRecognizer:lp];
        [row addTarget:self action:@selector(_clipTapped:)
              forControlEvents:UIControlEventTouchUpInside];
        [_clipContainer addSubview:row];
        [rows addObject:row];
    }
    _clipRows = rows;
    [self.view setNeedsLayout];
}

- (void)_reloadPhotos {
    [_photosView reloadData];
    [self _loadVisiblePhotoThumbs];
}

/// 为当前可见相册 cell 拉缩略图
- (void)_loadVisiblePhotoThumbs {
    NSArray *assets = [OSPhotosSource shared].assets;
    for (NSIndexPath *ip in [_photosView indexPathsForVisibleItems]) {
        if ((NSUInteger)ip.item >= assets.count) continue;
        id asset = assets[ip.item];
        [OSRuntime thumbnailForAsset:asset
                          targetSize:CGSizeMake(96, 96)
                          completion:^(UIImage *image) {
            dispatch_async(dispatch_get_main_queue(), ^{
                if (!image) return;
                OSPhotoCell *cell =
                    (OSPhotoCell *)[self->_photosView cellForItemAtIndexPath:ip];
                if (cell) cell.imageView.image = image;
            });
        }];
    }
}

// ---------------------------------------------------------------------------
#pragma mark - 展开 / 收起

- (BOOL)isExpanded {
    return _expanded;
}

- (void)setExpanded:(BOOL)expanded animated:(BOOL)animated {
    if (_expanded == expanded) {
        if (expanded) [self _layoutAll];
        return;
    }
    _expanded = expanded;
    _dimView.hidden = NO;
    _handleView.hidden = expanded; // 展开后把手让位

    void (^changes)(void) = ^{
        if (expanded) {
            self->_dimView.alpha = 0.35;
            self->_handleView.alpha = 0;
        } else {
            self->_dimView.alpha = 0;
            self->_handleView.alpha = 1;
        }
        [self _layoutAll];
    };
    void (^done)(BOOL) = ^(BOOL f) {
        if (!expanded) {
            self->_dimView.hidden = YES;
            self->_handleView.hidden = NO;
        }
    };
    if (!animated) {
        changes();
        done(YES);
        return;
    }
    [UIView animateWithDuration:0.24
                          delay:0
         usingSpringWithDamping:0.95
          initialSpringVelocity:0.4
                        options:UIViewAnimationOptionCurveEaseOut
                     animations:changes
                     completion:done];
}

- (void)_dimTapped {
    if (_expanded) [self _requestClose];
}

- (void)_handleTapped {
    if (!_expanded) [self setExpanded:YES animated:YES];
}

- (void)_handlePanned:(UIPanGestureRecognizer *)g {
    if (_expanded) return;
    if (g.state == UIGestureRecognizerStateEnded ||
        g.state == UIGestureRecognizerStateCancelled ||
        g.state == UIGestureRecognizerStateFailed) {
        return;
    }
    CGPoint v = [g velocityInView:self.view];
    if (v.x < -80) [self setExpanded:YES animated:YES];
}

- (void)_panelPanned:(UIPanGestureRecognizer *)g {
    if (!_expanded) return;
    if (g.state == UIGestureRecognizerStateEnded) {
        CGPoint v = [g velocityInView:self.view];
        if (v.x > 120) [self _requestClose];
    }
}

- (void)_closeTapped {
    [self _requestClose];
}

- (void)_requestClose {
    [self setExpanded:NO animated:YES];
    [self.delegate panelDidRequestClose:self];
}

// 面板上滚动 App 网格时，禁止被“向左拖收起”手势抢占
- (BOOL)gestureRecognizer:(UIGestureRecognizer *)gestureRecognizer
shouldRecognizeSimultaneouslyWithGestureRecognizer:(UIGestureRecognizer *)other {
    return NO;
}

// ---------------------------------------------------------------------------
#pragma mark - 托盘事件

- (void)_clipTapped:(OSClipRowView *)row {
    if (row.clipText.length) {
        [self.delegate panel:self didTapClipText:row.clipText];
    }
}

- (void)_clipLongPressed:(UILongPressGestureRecognizer *)g {
    CGPoint wpt = [g locationInView:nil];
    if (g.state == UIGestureRecognizerStateBegan) {
        OSClipRowView *row = (OSClipRowView *)g.view;
        if (!row.clipText.length) return;

        OSDragPayload *p = [OSDragPayload new];
        p.kind = OSItemKindText;
        p.text = row.clipText;
        p.sourceTitle = @"剪贴板";

        UIView *snap = [row snapshotViewAfterScreenUpdates:NO];
        snap.frame = [row convertRect:row.bounds toView:nil];

        _activeSourceRow = row;
        row.alpha = 0.45;
        [self.delegate panel:self didBeginDragWithPayload:p snapshot:snap
             atWindowPoint:wpt];
    } else if (g.state == UIGestureRecognizerStateChanged) {
        [self.delegate panel:self dragMovedToWindowPoint:wpt];
    } else if (g.state == UIGestureRecognizerStateEnded ||
               g.state == UIGestureRecognizerStateCancelled ||
               g.state == UIGestureRecognizerStateFailed) {
        [self.delegate panel:self dragEndedAtWindowPoint:wpt
                   cancelled:(g.state != UIGestureRecognizerStateEnded)];
    }
}

- (void)_photoLongPressed:(UILongPressGestureRecognizer *)g {
    CGPoint wpt = [g locationInView:nil];
    if (g.state == UIGestureRecognizerStateBegan) {
        CGPoint local = [g locationInView:_photosView];
        NSIndexPath *ip = [_photosView indexPathForItemAtPoint:local];
        NSArray *assets = [OSPhotosSource shared].assets;
        if (!ip || (NSUInteger)ip.item >= assets.count) return;
        id asset = assets[ip.item];

        OSDragPayload *p = [OSDragPayload new];
        p.kind = OSItemKindImage;
        p.sourceTitle = @"相册";
        p.imageUTI = @"public.jpeg";
        // 原图异步取：拖拽期间后台加载，松手时可能尚未完成 → 执行层经
        // imageProvider 等待，见 OSActionPlanner
        __weak id weakAsset = asset;
        p.imageProvider = ^(void (^done)(NSData *data)) {
            [OSRuntime imageDataForAsset:weakAsset completion:done];
        };

        UICollectionViewCell *cell = [_photosView cellForItemAtIndexPath:ip];
        UIView *snap = [cell snapshotViewAfterScreenUpdates:NO];
        snap.frame = [cell convertRect:cell.bounds toView:nil];

        [self.delegate panel:self didBeginDragWithPayload:p snapshot:snap
             atWindowPoint:wpt];
    } else if (g.state == UIGestureRecognizerStateChanged) {
        [self.delegate panel:self dragMovedToWindowPoint:wpt];
    } else if (g.state == UIGestureRecognizerStateEnded ||
               g.state == UIGestureRecognizerStateCancelled ||
               g.state == UIGestureRecognizerStateFailed) {
        [self.delegate panel:self dragEndedAtWindowPoint:wpt
                   cancelled:(g.state != UIGestureRecognizerStateEnded)];
    }
}

- (void)_actionTapped:(OSActionButton *)btn {
    if (_expanded && btn.action) {
        [self.delegate panel:self didTriggerAction:btn.action];
    }
}

// ---------------------------------------------------------------------------
#pragma mark - 拖放命中

- (id)dropTargetAtWindowPoint:(CGPoint)p {
    if (!_expanded) return nil;

    // 1) 快捷动作按钮
    for (OSActionButton *b in _actionButtons) {
        if (CGRectContainsPoint([b convertRect:b.bounds toView:nil], p)) {
            return b.action;
        }
    }
    // 2) 应用网格可见 cell
    for (OSAppCell *cell in [_appsView visibleCells]) {
        if (CGRectContainsPoint([cell convertRect:cell.bounds toView:nil], p)) {
            // 通过 dataSource 索引回模型
            NSIndexPath *ip = [_appsView indexPathForCell:cell];
            NSArray *apps = [OSAppSource shared].apps;
            if (ip && (NSUInteger)ip.item < apps.count) return apps[ip.item];
            return nil;
        }
    }
    return nil;
}

- (void)highlightTarget:(id)target {
    OSAppCell *wantCell = nil;
    OSActionButton *wantAction = nil;
    if ([target isKindOfClass:OSAppItem.class]) {
        for (OSAppCell *cell in [_appsView visibleCells]) {
            NSIndexPath *ip = [_appsView indexPathForCell:cell];
            NSArray *apps = [OSAppSource shared].apps;
            if (ip && (NSUInteger)ip.item < apps.count &&
                [apps[ip.item] isEqual:target]) {
                wantCell = cell;
                break;
            }
        }
    } else if ([target isKindOfClass:OSActionItem.class]) {
        for (OSActionButton *b in _actionButtons) {
            if ([b.action isEqual:target]) {
                wantAction = b;
                break;
            }
        }
    }

    if (_highlightedAppCell != wantCell) {
        [_highlightedAppCell setDropHighlighted:NO];
        _highlightedAppCell = wantCell;
        [_highlightedAppCell setDropHighlighted:YES];
    }
    if (_highlightedAction != wantAction) {
        _highlightedAction.backgroundColor =
            [UIColor colorWithWhite:1 alpha:0.0];
        _highlightedAction = wantAction;
        _highlightedAction.backgroundColor =
            [UIColor colorWithWhite:1 alpha:0.18];
    }
}

- (void)restoreSourceHighlight {
    _activeSourceRow.alpha = 1.0;
    _activeSourceRow = nil;
}

// ---------------------------------------------------------------------------
#pragma mark - UICollectionView

- (NSInteger)numberOfSectionsInCollectionView:(UICollectionView *)cv {
    return 1;
}

- (NSInteger)collectionView:(UICollectionView *)cv
     numberOfItemsInSection:(NSInteger)section {
    if (cv == _appsView) return [OSAppSource shared].apps.count;
    if (cv == _photosView) return [OSPhotosSource shared].assets.count;
    return 0;
}

- (UICollectionViewCell *)collectionView:(UICollectionView *)cv
                  cellForItemAtIndexPath:(NSIndexPath *)ip {
    if (cv == _appsView) {
        OSAppCell *cell = [cv dequeueReusableCellWithReuseIdentifier:OSAppCellID
                                                        forIndexPath:ip];
        NSArray *apps = [OSAppSource shared].apps;
        OSAppItem *item = (NSUInteger)ip.item < apps.count ? apps[ip.item] : nil;
        cell.nameLabel.text = item.displayName ?: @"";
        cell.iconView.image = nil;
        [self _loadAppIconForCell:cell bundleID:item.bundleID atIndexPath:ip];
        return cell;
    }
    // photos
    OSPhotoCell *cell = [cv dequeueReusableCellWithReuseIdentifier:OSPhotoCellID
                                                      forIndexPath:ip];
    cell.imageView.image = nil;
    return cell;
}

- (void)_loadAppIconForCell:(OSAppCell *)cell bundleID:(NSString *)bid
                atIndexPath:(NSIndexPath *)ip {
    if (!bid.length) return;
    UIImage *cached = [OSRuntime iconForBundleID:bid];
    if (cached) {
        cell.iconView.image = cached;
        return;
    }
    // 占位：首字母
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        // 图标解码较重，扔后台再试一次（仍失败则留占位符）
        UIImage *icon = [OSRuntime iconForBundleID:bid];
        dispatch_async(dispatch_get_main_queue(), ^{
            OSAppCell *now = (OSAppCell *)[self->_appsView cellForItemAtIndexPath:ip];
            if (now) now.iconView.image = icon;
        });
    });
}

- (CGSize)collectionView:(UICollectionView *)cv
                  layout:(UICollectionViewLayout *)cvLayout
  sizeForItemAtIndexPath:(NSIndexPath *)ip {
    if (cv == _appsView) {
        CGFloat w = cv.bounds.size.width;
        CGFloat itemW = floor((w - 4) / 3.0);
        return CGSizeMake(itemW, 66);
    }
    return CGSizeMake(48, 48);
}

- (UIEdgeInsets)collectionView:(UICollectionView *)cv
                        layout:(UICollectionViewLayout *)cvLayout
        insetForSectionAtIndex:(NSInteger)section {
    return UIEdgeInsetsZero;
}

- (void)collectionView:(UICollectionView *)cv
       willDisplayCell:(UICollectionViewCell *)cell
    forItemAtIndexPath:(NSIndexPath *)ip {
    if (cv == _photosView) [self _loadVisiblePhotoThumbs];
}

- (void)scrollViewDidScroll:(UIScrollView *)sv {
    if (sv == _photosView) [self _loadVisiblePhotoThumbs];
}

- (void)collectionView:(UICollectionView *)cv didSelectItemAtIndexPath:(NSIndexPath *)ip {
    // 点击相册缩略 = 复制该图到剪贴板
    if (cv == _photosView) {
        NSArray *assets = [OSPhotosSource shared].assets;
        if ((NSUInteger)ip.item < assets.count) {
            id asset = assets[ip.item];
            [OSRuntime imageDataForAsset:asset completion:^(NSData *data) {
                if (data.length) {
                    UIPasteboard *gp = [UIPasteboard generalPasteboard];
                    gp.items = @[ @{ (NSString *)@"public.jpeg" : data } ];
                }
            }];
        }
        [cv deselectItemAtIndexPath:ip animated:YES];
    }
}

@end
