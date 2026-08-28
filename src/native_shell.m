#import <Cocoa/Cocoa.h>
#import <QuickLookThumbnailing/QuickLookThumbnailing.h>

extern char *finder_native_catalog_json(void);
extern char *finder_native_related_json(const char *kind, const char *id);
extern void finder_native_free_string(char *value);
extern void finder_native_action(const char *kind, const char *ids, const char *action);
extern bool finder_native_rename(const char *kind, const char *id, const char *name);

// NSMenu key-equivalent handling can temporarily clear NSApp.keyWindow. Keep
// the last key window strongly until its close action finishes.
static NSWindow *lastKeyWindow;

@interface FinderNativeTable : NSTableView
@property(nonatomic, weak) id owner;
@property(nonatomic) NSInteger hoveredRow;
@end

typedef NS_ENUM(NSInteger, FinderResizeEdge) { FinderResizeEdgeRight, FinderResizeEdgeBottom, FinderResizeEdgeCorner };

@interface FinderResizeGrip : NSView
@property(nonatomic) FinderResizeEdge edge;
@property(nonatomic) NSPoint startMouse;
@property(nonatomic) NSRect startFrame;
@end

@interface FinderDragHeader : NSView
@property(nonatomic) NSTextField *titleLabel;
@property(nonatomic) NSPoint startMouse;
@property(nonatomic) NSRect startFrame;
@end

@interface FinderRecordCell : NSTableCellView
@property(nonatomic) NSImageView *thumbnailView;
@property(nonatomic) NSTextField *titleView;
@property(nonatomic, copy) NSString *thumbnailPayload;
@property(nonatomic) QLThumbnailGenerationRequest *thumbnailRequest;
@end

@interface FinderThumbnailManager : NSObject
@property(nonatomic) NSCache<NSString *, NSImage *> *cache;
+ (instancetype)shared;
- (void)loadPayload:(NSString *)payload intoCell:(FinderRecordCell *)cell scale:(CGFloat)scale;
@end

@interface FinderRelatedController : NSObject <NSWindowDelegate, NSTableViewDataSource, NSTableViewDelegate>
@property(nonatomic) NSWindow *window;
@property(nonatomic) NSTableView *table;
@property(nonatomic) NSScrollView *scroll;
@property(nonatomic) FinderDragHeader *header;
@property(nonatomic) NSArray *items;
@end

@interface FinderRelatedTable : NSTableView
@property(nonatomic, weak) FinderRelatedController *owner;
@end

@interface FinderNativeController : NSObject <NSApplicationDelegate, NSWindowDelegate, NSTableViewDataSource, NSTableViewDelegate>
@property(nonatomic) NSWindow *window;
@property(nonatomic) FinderNativeTable *table;
@property(nonatomic) NSScrollView *scroll;
@property(nonatomic) NSArray *columns;
@property(nonatomic) NSArray *records;
@property(nonatomic) NSString *activeKind;
@property(nonatomic) FinderDragHeader *header;
@property(nonatomic) NSMutableArray *relatedControllers;
- (void)setupMainWindow;
@end

@implementation FinderNativeTable
- (void)mouseDown:(NSEvent *)event {
  NSEventModifierFlags modifiers = event.modifierFlags;
  BOOL openOriginal = (modifiers & NSEventModifierFlagOption) != 0;
  BOOL extendSelection = (modifiers & (NSEventModifierFlagCommand | NSEventModifierFlagShift | NSEventModifierFlagControl)) != 0;
  NSInteger clickedRow = [self rowAtPoint:[self convertPoint:event.locationInWindow fromView:nil]];
  BOOL wasSelected = clickedRow >= 0 && [self.selectedRowIndexes containsIndex:(NSUInteger)clickedRow];
  if (openOriginal && wasSelected) {
    [(FinderNativeController *)self.owner performSelector:@selector(open:) withObject:nil];
    return;
  }
  [super mouseDown:event];
  if (self.selectedRow < 0) return;
  FinderNativeController *controller = (FinderNativeController *)self.owner;
  if (openOriginal) [controller performSelector:@selector(open:) withObject:nil];
  else if (!extendSelection && wasSelected) [controller performSelector:@selector(quickLook:) withObject:nil];
}
- (void)updateTrackingAreas {
  [super updateTrackingAreas];
  [self addTrackingArea:[[NSTrackingArea alloc] initWithRect:self.bounds options:NSTrackingMouseMoved | NSTrackingActiveInKeyWindow | NSTrackingInVisibleRect owner:self userInfo:nil]];
}
- (void)mouseMoved:(NSEvent *)event { self.hoveredRow = [self rowAtPoint:[self convertPoint:event.locationInWindow fromView:nil]]; }
@end

@implementation FinderResizeGrip
- (void)resetCursorRects {
  if (self.edge == FinderResizeEdgeRight) [self addCursorRect:self.bounds cursor:NSCursor.resizeLeftRightCursor];
  else if (self.edge == FinderResizeEdgeBottom) [self addCursorRect:self.bounds cursor:NSCursor.resizeUpDownCursor];
  else [self addCursorRect:self.bounds cursor:NSCursor.crosshairCursor];
}
- (void)mouseDown:(NSEvent *)event { self.startMouse = NSEvent.mouseLocation; self.startFrame = self.window.frame; }
- (void)mouseDragged:(NSEvent *)event {
  NSPoint now = NSEvent.mouseLocation;
  CGFloat dx = now.x - self.startMouse.x, dy = now.y - self.startMouse.y;
  NSRect frame = self.startFrame;
  if (self.edge == FinderResizeEdgeRight || self.edge == FinderResizeEdgeCorner) frame.size.width = MAX(self.window.minSize.width, frame.size.width + dx);
  if (self.edge == FinderResizeEdgeBottom || self.edge == FinderResizeEdgeCorner) {
    CGFloat height = MAX(self.window.minSize.height, self.startFrame.size.height - dy);
    frame.origin.y = self.startFrame.origin.y + self.startFrame.size.height - height;
    frame.size.height = height;
  }
  [self.window setFrame:frame display:YES];
}
@end

@implementation FinderDragHeader
- (instancetype)initWithFrame:(NSRect)frameRect {
  if (!(self = [super initWithFrame:frameRect])) return nil;
  self.titleLabel = [NSTextField labelWithString:@""];
  self.titleLabel.frame = NSMakeRect(12, 2, 260, 20);
  self.titleLabel.font = [NSFont systemFontOfSize:14];
  self.titleLabel.textColor = NSColor.labelColor;
  self.titleLabel.autoresizingMask = NSViewWidthSizable;
  [self addSubview:self.titleLabel];
  return self;
}
- (void)drawRect:(NSRect)dirtyRect {
  [super drawRect:dirtyRect];
  [NSColor.controlBackgroundColor setFill];
  NSRectFill(self.bounds);
  [NSColor.separatorColor setFill];
  NSRectFill(NSMakeRect(0, 0, self.bounds.size.width, 1));
}
- (void)mouseDown:(NSEvent *)event { self.startMouse = NSEvent.mouseLocation; self.startFrame = self.window.frame; }
- (void)mouseDragged:(NSEvent *)event {
  NSPoint now = NSEvent.mouseLocation;
  NSRect frame = self.startFrame;
  frame.origin.x += now.x - self.startMouse.x;
  frame.origin.y += now.y - self.startMouse.y;
  [self.window setFrameOrigin:frame.origin];
}
@end

@implementation FinderRecordCell
- (instancetype)initWithFrame:(NSRect)frameRect {
  if (!(self = [super initWithFrame:frameRect])) return nil;
  self.thumbnailView = [[NSImageView alloc] initWithFrame:NSZeroRect];
  self.thumbnailView.imageScaling = NSImageScaleProportionallyUpOrDown;
  self.thumbnailView.imageAlignment = NSImageAlignCenter;
  [self addSubview:self.thumbnailView];
  self.titleView = [NSTextField labelWithString:@""];
  self.titleView.font = [NSFont systemFontOfSize:14];
  self.titleView.lineBreakMode = NSLineBreakByClipping;
  self.titleView.usesSingleLineMode = YES;
  [self addSubview:self.titleView];
  return self;
}
- (void)layout {
  [super layout];
  const CGFloat thumbnailSize = 28;
  const CGFloat leading = 0;
  const CGFloat titleLeading = leading + thumbnailSize + 8;
  const CGFloat trailing = 4;
  const CGFloat titleHeight = 22;
  CGFloat height = NSHeight(self.bounds);
  self.thumbnailView.frame = NSMakeRect(leading, floor((height - thumbnailSize) / 2.0), thumbnailSize, thumbnailSize);
  self.titleView.frame = NSMakeRect(titleLeading, floor((height - titleHeight) / 2.0) - 1, MAX(0, NSWidth(self.bounds) - titleLeading - trailing), titleHeight);
}
- (void)prepareForReuse {
  [super prepareForReuse];
  [[QLThumbnailGenerator sharedGenerator] cancelRequest:self.thumbnailRequest]; self.thumbnailRequest = nil;
  self.thumbnailPayload = nil; self.thumbnailView.image = nil; self.titleView.stringValue = @"";
}
@end

@implementation FinderThumbnailManager
+ (instancetype)shared {
  static FinderThumbnailManager *manager; static dispatch_once_t once;
  dispatch_once(&once, ^{ manager = [FinderThumbnailManager new]; manager.cache = [NSCache new]; manager.cache.countLimit = 512; });
  return manager;
}
- (NSString *)cacheKeyForPayload:(NSString *)payload {
  NSDictionary *attrs = [[NSFileManager defaultManager] attributesOfItemAtPath:payload error:nil];
  NSDate *modified = attrs[NSFileModificationDate] ?: [NSDate distantPast];
  NSNumber *size = attrs[NSFileSize] ?: @0;
  return [NSString stringWithFormat:@"%@|%.6f|%@", payload, modified.timeIntervalSince1970, size];
}
- (void)loadPayload:(NSString *)payload intoCell:(FinderRecordCell *)cell scale:(CGFloat)scale {
  [[QLThumbnailGenerator sharedGenerator] cancelRequest:cell.thumbnailRequest]; cell.thumbnailRequest = nil;
  cell.thumbnailPayload = payload;
  cell.thumbnailView.image = [[NSWorkspace sharedWorkspace] iconForFile:payload];
  if (!payload.length || ![[NSFileManager defaultManager] fileExistsAtPath:payload]) return;
  NSString *key = [self cacheKeyForPayload:payload];
  NSImage *cached = [self.cache objectForKey:key];
  if (cached) { cell.thumbnailView.image = cached; return; }
  QLThumbnailGenerationRequest *request = [[QLThumbnailGenerationRequest alloc] initWithFileAtURL:[NSURL fileURLWithPath:payload] size:CGSizeMake(30, 30) scale:MAX(scale, 1.0) representationTypes:QLThumbnailGenerationRequestRepresentationTypeThumbnail];
  request.iconMode = NO;
  cell.thumbnailRequest = request;
  __weak FinderRecordCell *weakCell = cell;
  [[QLThumbnailGenerator sharedGenerator] generateBestRepresentationForRequest:request completionHandler:^(QLThumbnailRepresentation *thumbnail, NSError *error) {
    if (!thumbnail.NSImage || error) return;
    NSImage *image = thumbnail.NSImage;
    [self.cache setObject:image forKey:key];
    dispatch_async(dispatch_get_main_queue(), ^{
      FinderRecordCell *currentCell = weakCell;
      if (currentCell && currentCell.thumbnailRequest == request && [currentCell.thumbnailPayload isEqualToString:payload]) {
        currentCell.thumbnailView.image = image;
        currentCell.thumbnailRequest = nil;
      }
    });
  }];
}
@end

@implementation FinderRelatedController
- (instancetype)initWithCatalog:(NSDictionary *)catalog parent:(NSWindow *)parent {
  if (!(self = [super init])) return nil;
  NSMutableArray *items = [NSMutableArray array];
  for (NSDictionary *column in catalog[@"columns"] ?: @[]) {
    for (NSDictionary *record in column[@"records"] ?: @[]) {
      [items addObject:@{ @"kind": column[@"kind"] ?: @"", @"id": record[@"id"] ?: @"", @"title": record[@"title"] ?: record[@"id"] ?: @"", @"label": column[@"label"] ?: column[@"kind"] ?: @"", @"payload": record[@"payload"] ?: @"", @"preview": record[@"preview"] ?: @"" }];
    }
  }
  self.items = items;
  self.window = [[NSWindow alloc] initWithContentRect:NSMakeRect(parent.frame.origin.x + 28, parent.frame.origin.y + 28, 300, 360) styleMask:NSWindowStyleMaskBorderless | NSWindowStyleMaskResizable backing:NSBackingStoreBuffered defer:NO];
  self.window.delegate = self;
  self.window.movableByWindowBackground = YES; self.window.hasShadow = NO; self.window.backgroundColor = NSColor.windowBackgroundColor; self.window.minSize = NSMakeSize(180, 140);
  NSView *content = self.window.contentView;
  self.header = [[FinderDragHeader alloc] initWithFrame:NSMakeRect(0, 336, 300, 24)];
  self.header.autoresizingMask = NSViewWidthSizable | NSViewMinYMargin;
  self.header.titleLabel.stringValue = [NSString stringWithFormat:@"Links · %@", catalog[@"title"] ?: @""];
  [content addSubview:self.header];
  self.scroll = [[NSScrollView alloc] initWithFrame:NSMakeRect(0, 0, 300, 336)];
  self.scroll.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable; self.scroll.hasVerticalScroller = YES; self.scroll.borderType = NSNoBorder;
  self.table = [[FinderRelatedTable alloc] initWithFrame:self.scroll.bounds];
  ((FinderRelatedTable *)self.table).owner = self; self.table.headerView = nil; self.table.allowsMultipleSelection = YES; self.table.allowsEmptySelection = YES;
  self.table.usesAlternatingRowBackgroundColors = NO; self.table.backgroundColor = NSColor.clearColor; self.table.rowHeight = 34; self.table.intercellSpacing = NSMakeSize(0, 0);
  self.table.autoresizingMask = NSViewWidthSizable; self.table.columnAutoresizingStyle = NSTableViewFirstColumnOnlyAutoresizingStyle; self.table.delegate = self; self.table.dataSource = self;
  NSTableColumn *column = [[NSTableColumn alloc] initWithIdentifier:@"related"]; column.width = 300; column.resizingMask = NSTableColumnAutoresizingMask; [self.table addTableColumn:column]; self.scroll.documentView = self.table; [content addSubview:self.scroll];
  for (NSNumber *edge in @[@(FinderResizeEdgeRight), @(FinderResizeEdgeBottom), @(FinderResizeEdgeCorner)]) {
    FinderResizeGrip *grip = [[FinderResizeGrip alloc] initWithFrame:NSZeroRect]; grip.edge = edge.integerValue;
    if (grip.edge == FinderResizeEdgeRight) { grip.frame = NSMakeRect(294, 0, 6, 360); grip.autoresizingMask = NSViewMinXMargin | NSViewHeightSizable; }
    else if (grip.edge == FinderResizeEdgeBottom) { grip.frame = NSMakeRect(0, 0, 300, 6); grip.autoresizingMask = NSViewWidthSizable | NSViewMaxYMargin; }
    else { grip.frame = NSMakeRect(290, 0, 10, 10); grip.autoresizingMask = NSViewMinXMargin | NSViewMaxYMargin; }
    [content addSubview:grip];
  }
  self.window.title = catalog[@"title"] ?: @"Links"; [self.window makeKeyAndOrderFront:nil]; return self;
}
- (NSInteger)numberOfRowsInTableView:(NSTableView *)table { return self.items.count; }
- (NSView *)tableView:(NSTableView *)table viewForTableColumn:(NSTableColumn *)column row:(NSInteger)row {
  FinderRecordCell *cell = [table makeViewWithIdentifier:@"related-cell" owner:self];
  if (!cell) { cell = [[FinderRecordCell alloc] initWithFrame:NSMakeRect(0, 0, table.bounds.size.width, 34)]; cell.identifier = @"related-cell"; }
  NSDictionary *item = self.items[(NSUInteger)row];
  cell.titleView.stringValue = [NSString stringWithFormat:@"%@  %@", item[@"label"], item[@"title"]];
  [cell setNeedsLayout:YES];
  [[FinderThumbnailManager shared] loadPayload:item[@"preview"] ?: item[@"payload"] intoCell:cell scale:self.window.backingScaleFactor ?: 1.0];
  return cell;
}
- (void)openSelected {
  [self actOnSelected:@"open"];
}
- (void)windowDidBecomeKey:(NSNotification *)notification { lastKeyWindow = self.window; }
- (void)windowDidResize:(NSNotification *)notification {
  CGFloat width = self.scroll.contentView.bounds.size.width;
  NSRect frame = self.table.frame;
  frame.size.width = width;
  self.table.frame = frame;
  self.table.tableColumns.firstObject.width = width;
  [self.table reloadData];
}
- (void)quickLookSelected {
  if (self.table.selectedRow < 0) return;
  NSMutableArray<NSString *> *ids = [NSMutableArray array];
  __block NSString *kind = nil;
  [self.table.selectedRowIndexes enumerateIndexesUsingBlock:^(NSUInteger row, BOOL *stop) {
    (void)stop;
    NSDictionary *item = self.items[row];
    if (!kind) kind = item[@"kind"];
    if (item[@"id"]) [ids addObject:item[@"id"]];
  }];
  NSData *data = [NSJSONSerialization dataWithJSONObject:ids options:0 error:nil];
  NSString *json = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
  if (kind && json) finder_native_action(kind.UTF8String, json.UTF8String, "quicklook");
}
- (void)actOnSelected:(NSString *)action {
  if (self.table.selectedRow < 0) return;
  NSMutableDictionary<NSString *, NSMutableArray<NSString *> *> *idsByKind = [NSMutableDictionary dictionary];
  [self.table.selectedRowIndexes enumerateIndexesUsingBlock:^(NSUInteger row, BOOL *stop) {
    (void)stop;
    NSDictionary *item = self.items[row]; NSString *kind = item[@"kind"]; NSString *recordId = item[@"id"];
    if (kind && recordId) { if (!idsByKind[kind]) idsByKind[kind] = [NSMutableArray array]; [idsByKind[kind] addObject:recordId]; }
  }];
  for (NSString *kind in idsByKind) {
    NSData *data = [NSJSONSerialization dataWithJSONObject:idsByKind[kind] options:0 error:nil];
    NSString *json = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    finder_native_action(kind.UTF8String, json.UTF8String, action.UTF8String);
  }
}
@end

@implementation FinderRelatedTable
- (void)mouseDown:(NSEvent *)event {
  NSEventModifierFlags modifiers = event.modifierFlags;
  NSInteger clickedRow = [self rowAtPoint:[self convertPoint:event.locationInWindow fromView:nil]];
  BOOL wasSelected = clickedRow >= 0 && [self.selectedRowIndexes containsIndex:(NSUInteger)clickedRow];
  if ((modifiers & NSEventModifierFlagOption) && wasSelected) { [self.owner openSelected]; return; }
  [super mouseDown:event];
  if (self.selectedRow < 0) return;
  if (modifiers & NSEventModifierFlagOption) [self.owner openSelected];
  else if (!(modifiers & (NSEventModifierFlagCommand | NSEventModifierFlagShift | NSEventModifierFlagControl)) && wasSelected) [self.owner quickLookSelected];
}
@end

@implementation FinderNativeController

- (void)applicationDidFinishLaunching:(NSNotification *)note { [self setupMainWindow]; }

- (void)setupMainWindow {
  NSRect frame = NSMakeRect(0, 0, 300, 420);
  self.window = [[NSWindow alloc] initWithContentRect:frame styleMask:NSWindowStyleMaskBorderless | NSWindowStyleMaskResizable backing:NSBackingStoreBuffered defer:NO];
  self.window.movableByWindowBackground = YES;
  self.window.delegate = self;
  self.window.hasShadow = NO;
  self.window.backgroundColor = NSColor.windowBackgroundColor;
  self.window.minSize = NSMakeSize(180, 140);
  [self.window center];
  NSView *content = self.window.contentView;

  self.header = [[FinderDragHeader alloc] initWithFrame:NSMakeRect(0, 396, 300, 24)];
  self.header.autoresizingMask = NSViewWidthSizable | NSViewMinYMargin;
  [content addSubview:self.header];
  self.scroll = [[NSScrollView alloc] initWithFrame:NSMakeRect(0, 0, 300, 396)];
  self.scroll.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
  self.scroll.hasVerticalScroller = YES;
  self.scroll.borderType = NSNoBorder;
  self.table = [[FinderNativeTable alloc] initWithFrame:self.scroll.bounds];
  self.table.owner = self;
  self.table.hoveredRow = -1;
  self.relatedControllers = [NSMutableArray array];
  self.table.headerView = nil;
  self.table.allowsMultipleSelection = YES;
  self.table.allowsEmptySelection = YES;
  self.table.usesAlternatingRowBackgroundColors = NO;
  self.table.backgroundColor = NSColor.clearColor;
  self.table.rowHeight = 34;
  self.table.intercellSpacing = NSMakeSize(0, 0);
  self.table.autoresizingMask = NSViewWidthSizable;
  self.table.columnAutoresizingStyle = NSTableViewFirstColumnOnlyAutoresizingStyle;
  self.table.delegate = self; self.table.dataSource = self;
  NSTableColumn *column = [[NSTableColumn alloc] initWithIdentifier:@"record"];
  column.width = 300; column.resizingMask = NSTableColumnAutoresizingMask; [self.table addTableColumn:column];
  self.scroll.documentView = self.table; [content addSubview:self.scroll];
  for (NSNumber *edge in @[@(FinderResizeEdgeRight), @(FinderResizeEdgeBottom), @(FinderResizeEdgeCorner)]) {
    FinderResizeGrip *grip = [[FinderResizeGrip alloc] initWithFrame:NSZeroRect];
    grip.edge = edge.integerValue;
    if (grip.edge == FinderResizeEdgeRight) { grip.frame = NSMakeRect(294, 0, 6, 420); grip.autoresizingMask = NSViewMinXMargin | NSViewHeightSizable; }
    else if (grip.edge == FinderResizeEdgeBottom) { grip.frame = NSMakeRect(0, 0, 300, 6); grip.autoresizingMask = NSViewWidthSizable | NSViewMaxYMargin; }
    else { grip.frame = NSMakeRect(290, 0, 10, 10); grip.autoresizingMask = NSViewMinXMargin | NSViewMaxYMargin; }
    [content addSubview:grip];
  }
  [self loadCatalog];
  [self installMenu];
  [self.window makeKeyAndOrderFront:nil];
  [NSApp activateIgnoringOtherApps:YES];
}

- (void)installMenu {
  NSMenu *bar = [NSMenu new];
  NSMenuItem *appItem = [NSMenuItem new]; [bar addItem:appItem];
  NSMenu *app = [[NSMenu alloc] initWithTitle:@"Finder Finder"];
  [app addItemWithTitle:@"Quit Finder Finder" action:@selector(terminate:) keyEquivalent:@"q"];
  appItem.submenu = app;
  NSMenuItem *fileItem = [NSMenuItem new]; [bar addItem:fileItem];
  NSMenu *file = [[NSMenu alloc] initWithTitle:@"File"];
  NSMenuItem *close = [file addItemWithTitle:@"Close Window" action:@selector(closeWindow:) keyEquivalent:@"w"];
  close.target = self;
  [file addItem:[NSMenuItem separatorItem]];
  [file addItemWithTitle:@"Open Metadata" action:@selector(metadata:) keyEquivalent:@"j"];
  NSMenuItem *rename = [file addItemWithTitle:@"Rename" action:@selector(renameSelected:) keyEquivalent:@"\r"];
  rename.target = self;
  [file addItemWithTitle:@"Reveal in Finder" action:@selector(reveal:) keyEquivalent:@"f"];
  NSMenuItem *openQuickLook = [file addItemWithTitle:@"Open Quick Look Original" action:@selector(openQuickLookOriginal:) keyEquivalent:@"o"];
  openQuickLook.target = self;
  NSMenuItem *copyPath = [file addItemWithTitle:@"Copy Path" action:@selector(copy:) keyEquivalent:@"p"];
  copyPath.target = self;
  fileItem.submenu = file; NSApp.mainMenu = bar;
  NSMenuItem *linkItem = [NSMenuItem new]; [bar addItem:linkItem];
  NSMenu *link = [[NSMenu alloc] initWithTitle:@"Link"];
  NSMenuItem *related = [link addItemWithTitle:@"Open Related" action:@selector(openRelated:) keyEquivalent:@"e"];
  related.keyEquivalentModifierMask = NSEventModifierFlagCommand;
  linkItem.submenu = link;
  NSMenuItem *categoryItem = [NSMenuItem new]; [bar addItem:categoryItem];
  NSMenu *categories = [[NSMenu alloc] initWithTitle:@"Category"];
  NSMutableSet<NSString *> *usedLetters = [NSMutableSet set];
  for (NSDictionary *column in self.columns) {
    NSString *kind = column[@"kind"] ?: @"";
    NSString *shortcut = nil;
    for (NSUInteger i = 0; i < kind.length; i++) {
      unichar ch = [kind characterAtIndex:i];
      if (![[NSCharacterSet letterCharacterSet] characterIsMember:ch]) continue;
      NSString *letter = [[NSString stringWithCharacters:&ch length:1] lowercaseString];
      if (![usedLetters containsObject:letter]) { shortcut = letter; [usedLetters addObject:letter]; break; }
    }
    NSMenuItem *item = [categories addItemWithTitle:column[@"label"] ?: kind action:@selector(selectCategory:) keyEquivalent:shortcut ?: @""];
    item.keyEquivalentModifierMask = NSEventModifierFlagOption;
    item.representedObject = kind; item.target = self;
  }
  categoryItem.submenu = categories;
}

- (void)loadCatalog {
  char *raw = finder_native_catalog_json();
  NSData *data = raw ? [NSData dataWithBytes:raw length:strlen(raw)] : nil;
  if (raw) finder_native_free_string(raw);
  NSDictionary *catalog = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
  self.columns = catalog[@"columns"] ?: @[];
  if (self.columns.count) [self chooseColumn:0]; else { self.records = @[]; [self.table reloadData]; }
}

- (void)chooseColumn:(NSInteger)index {
  if (index < 0 || index >= (NSInteger)self.columns.count) return;
  NSDictionary *column = self.columns[(NSUInteger)index];
  self.activeKind = column[@"kind"] ?: @"";
  self.header.titleLabel.stringValue = column[@"label"] ?: self.activeKind;
  self.records = column[@"records"] ?: @[];
  [self.table reloadData];
}
- (void)selectCategory:(NSMenuItem *)sender {
  NSString *kind = sender.representedObject;
  NSUInteger index = [self.columns indexOfObjectPassingTest:^BOOL(NSDictionary *column, NSUInteger idx, BOOL *stop) {
    (void)idx; (void)stop;
    return [column[@"kind"] isEqualToString:kind];
  }];
  if (index != NSNotFound) [self chooseColumn:(NSInteger)index];
}
- (NSInteger)numberOfRowsInTableView:(NSTableView *)table { return self.records.count; }
- (NSView *)tableView:(NSTableView *)table viewForTableColumn:(NSTableColumn *)column row:(NSInteger)row {
  FinderRecordCell *cell = [table makeViewWithIdentifier:@"record-cell" owner:self];
  if (!cell) { cell = [[FinderRecordCell alloc] initWithFrame:NSMakeRect(0, 0, table.bounds.size.width, 34)]; cell.identifier = @"record-cell"; }
  NSDictionary *record = self.records[(NSUInteger)row];
  cell.titleView.stringValue = record[@"title"] ?: record[@"id"] ?: @"";
  [cell setNeedsLayout:YES];
  CGFloat scale = self.window.backingScaleFactor ?: 1.0;
  [[FinderThumbnailManager shared] loadPayload:record[@"preview"] ?: record[@"payload"] ?: @"" intoCell:cell scale:scale];
  return cell;
}
- (NSArray<NSString *> *)selectedIds {
  NSMutableArray *ids = [NSMutableArray array];
  [self.table.selectedRowIndexes enumerateIndexesUsingBlock:^(NSUInteger row, BOOL *stop) { (void)stop; NSString *value = self.records[row][@"id"]; if (value) [ids addObject:value]; }];
  return ids;
}
- (NSString *)kind { return self.activeKind ?: @""; }
- (void)act:(NSString *)action {
  NSArray *ids = self.selectedIds; if (!ids.count && ![action isEqual:@"reveal"] && ![action isEqual:@"copy"]) return;
  NSData *data = [NSJSONSerialization dataWithJSONObject:ids options:0 error:nil];
  NSString *json = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] ?: @"[]";
  finder_native_action(self.kind.UTF8String, json.UTF8String, action.UTF8String);
}
- (void)tableView:(NSTableView *)tableView didDoubleClickRow:(NSInteger)row { [self act:@"open"]; }
- (void)quickLook:(id)sender { [self act:@"quicklook"]; }
- (void)open:(id)sender { [self act:@"open"]; }
- (void)metadata:(id)sender { [self act:@"metadata"]; }
- (void)reveal:(id)sender { [self act:@"reveal"]; }
- (void)copy:(id)sender { [self act:@"copy"]; }
- (void)openQuickLookOriginal:(id)sender { finder_native_action(self.kind.UTF8String, "[]", "open-ql"); }
- (void)closeWindow:(id)sender {
  NSWindow *window = NSApp.orderedWindows.firstObject ?: lastKeyWindow ?: self.window;
  lastKeyWindow = nil;
  [window close];
}
- (void)renameSelected:(id)sender {
  if (self.table.selectedRowIndexes.count != 1) return;
  NSDictionary *record = self.records[(NSUInteger)self.table.selectedRow];
  NSAlert *alert = [NSAlert new]; alert.messageText = @"Rename"; alert.informativeText = @"Display name";
  NSTextField *field = [[NSTextField alloc] initWithFrame:NSMakeRect(0, 0, 260, 24)]; field.stringValue = record[@"title"] ?: record[@"id"] ?: @""; alert.accessoryView = field;
  [alert addButtonWithTitle:@"Rename"]; [alert addButtonWithTitle:@"Cancel"];
  if ([alert runModal] != NSAlertFirstButtonReturn) return;
  if (finder_native_rename(self.kind.UTF8String, [record[@"id"] UTF8String], field.stringValue.UTF8String)) [self loadCatalog];
}
- (void)windowDidBecomeKey:(NSNotification *)notification { lastKeyWindow = self.window; }
- (void)windowDidResize:(NSNotification *)notification {
  CGFloat width = self.scroll.contentView.bounds.size.width;
  NSRect frame = self.table.frame;
  frame.size.width = width;
  self.table.frame = frame;
  self.table.tableColumns.firstObject.width = width;
  [self.table reloadData];
}
- (void)openRelated:(id)sender {
  if (NSApp.orderedWindows.firstObject != self.window) return;
  NSInteger row = self.table.selectedRow >= 0 ? self.table.selectedRow : self.table.hoveredRow;
  if (row < 0 || row >= (NSInteger)self.records.count) return;
  NSDictionary *record = self.records[(NSUInteger)row]; char *raw = finder_native_related_json(self.kind.UTF8String, [record[@"id"] UTF8String]);
  NSData *data = raw ? [NSData dataWithBytes:raw length:strlen(raw)] : nil; if (raw) finder_native_free_string(raw);
  NSDictionary *catalog = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil; if (!catalog || catalog[@"error"]) return;
  FinderRelatedController *controller = [[FinderRelatedController alloc] initWithCatalog:catalog parent:self.window]; [self.relatedControllers addObject:controller];
}
- (BOOL)validateMenuItem:(NSMenuItem *)item {
  if (item.action == @selector(openRelated:)) {
    return NSApp.orderedWindows.firstObject == self.window
        && (self.table.selectedRow >= 0 || self.table.hoveredRow >= 0);
  }
  return YES;
}
@end

void finder_native_run(void) {
  @autoreleasepool {
    NSApplication *app = [NSApplication sharedApplication];
    FinderNativeController *controller = [FinderNativeController new];
    app.delegate = controller;
    [app run];
  }
}
