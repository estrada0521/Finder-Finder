#import <Cocoa/Cocoa.h>
#import <CoreServices/CoreServices.h>
#import <QuickLookThumbnailing/QuickLookThumbnailing.h>

extern char *finder_native_catalog_json(void);
extern char *finder_native_db_root(void);
extern char *finder_native_related_json(const char *ids, bool direct_only);
extern char *finder_native_payloads_json(const char *kind, const char *ids);
extern char *finder_native_clipboard_files_json(const char *ids);
extern char *finder_native_create_record(const char *category, const char *name, const char *paths);
extern void finder_native_free_string(char *value);
extern void finder_native_action(const char *kind, const char *ids, const char *action);
extern bool finder_native_rename(const char *kind, const char *id, const char *name);
extern int finder_native_unlink(const char *seeds, const char *target);

// NSMenu key-equivalent handling can temporarily clear NSApp.keyWindow. Keep
// the last key window strongly until its close action finishes.
static NSWindow *lastKeyWindow;
static const CGFloat FinderHeaderHeight = 36;

@class FinderNativeController;
static void FinderDatabaseEvents(
    ConstFSEventStreamRef streamRef,
    void *clientCallBackInfo,
    size_t numEvents,
    void *eventPaths,
    const FSEventStreamEventFlags eventFlags[],
    const FSEventStreamEventId eventIds[]
);

@protocol FinderPayloadDragOwner <NSObject>
- (void)beginPayloadDragFromTable:(NSTableView *)table event:(NSEvent *)event;
@end

static NSArray<NSURL *> *FinderDroppedFileURLs(id<NSDraggingInfo> info) {
  return [info.draggingPasteboard readObjectsForClasses:@[NSURL.class] options:@{ NSPasteboardURLReadingFileURLsOnlyKey: @YES }] ?: @[];
}

// A drag this app started (payload drag out of a table) carries a non-nil
// draggingSource; a file drag from Finder does not. Dropping our own drag back
// onto the app must not create a record.
static BOOL FinderDragIsInternal(id<NSDraggingInfo> info) {
  return info.draggingSource != nil;
}

static NSDragOperation FinderPayloadDropOperation(id<NSDraggingInfo> info) {
  if (FinderDragIsInternal(info)) return NSDragOperationNone;
  return FinderDroppedFileURLs(info).count ? NSDragOperationCopy : NSDragOperationNone;
}

// Cmd-C: put the payload file(s) themselves on the general pasteboard so they
// paste into Finder / Mail / Slack etc. Multiple selected records and records
// with multiple payloads all contribute their files. During Quick Look the
// previewed item's payload wins (Rust decides via finder_native_clipboard_files_json).
static BOOL FinderCopyPayloadFiles(NSArray<NSString *> *ids) {
  NSData *request = [NSJSONSerialization dataWithJSONObject:(ids ?: @[]) options:0 error:nil];
  NSString *json = [[NSString alloc] initWithData:request encoding:NSUTF8StringEncoding] ?: @"[]";
  char *raw = finder_native_clipboard_files_json(json.UTF8String);
  NSData *response = raw ? [NSData dataWithBytes:raw length:strlen(raw)] : nil;
  if (raw) finder_native_free_string(raw);
  NSArray *paths = response ? [NSJSONSerialization JSONObjectWithData:response options:0 error:nil] : nil;
  if (![paths isKindOfClass:NSArray.class]) return NO;
  NSMutableArray<NSURL *> *urls = [NSMutableArray array];
  for (id path in paths) {
    if ([path isKindOfClass:NSString.class] && [path length]) [urls addObject:[NSURL fileURLWithPath:path]];
  }
  if (!urls.count) return NO;
  NSPasteboard *pasteboard = NSPasteboard.generalPasteboard;
  [pasteboard clearContents];
  return [pasteboard writeObjects:urls];
}

static NSArray<NSURL *> *FinderPayloadURLs(NSString *kind, NSArray<NSString *> *ids) {
  if (!kind.length || !ids.count) return @[];
  NSData *request = [NSJSONSerialization dataWithJSONObject:ids options:0 error:nil];
  NSString *json = [[NSString alloc] initWithData:request encoding:NSUTF8StringEncoding];
  char *raw = json ? finder_native_payloads_json(kind.UTF8String, json.UTF8String) : NULL;
  NSData *response = raw ? [NSData dataWithBytes:raw length:strlen(raw)] : nil;
  if (raw) finder_native_free_string(raw);
  NSArray *paths = response ? [NSJSONSerialization JSONObjectWithData:response options:0 error:nil] : nil;
  if (![paths isKindOfClass:NSArray.class]) return @[];
  NSMutableArray<NSURL *> *urls = [NSMutableArray array];
  for (id path in paths) {
    if ([path isKindOfClass:NSString.class] && [path length]) [urls addObject:[NSURL fileURLWithPath:path]];
  }
  return urls;
}

static void FinderBeginPayloadDrag(NSTableView *table, NSEvent *event, NSArray<NSURL *> *urls) {
  if (!urls.count) return;
  NSPoint point = [table convertPoint:event.locationInWindow fromView:nil];
  NSMutableArray<NSDraggingItem *> *items = [NSMutableArray arrayWithCapacity:urls.count];
  for (NSURL *url in urls) {
    NSDraggingItem *item = [[NSDraggingItem alloc] initWithPasteboardWriter:url];
    NSImage *icon = [[NSWorkspace sharedWorkspace] iconForFile:url.path] ?: [NSImage imageNamed:NSImageNameMultipleDocuments];
    [item setDraggingFrame:NSMakeRect(point.x - 14, point.y - 14, 28, 28) contents:icon];
    [items addObject:item];
  }
  [table beginDraggingSessionWithItems:items event:event source:(id<NSDraggingSource>)table];
}

static void FinderSelectRow(NSTableView *table, NSInteger row, NSEventModifierFlags modifiers, BOOL wasSelected) {
  if (modifiers & (NSEventModifierFlagCommand | NSEventModifierFlagControl)) {
    NSMutableIndexSet *selection = table.selectedRowIndexes.mutableCopy;
    if (wasSelected) [selection removeIndex:(NSUInteger)row]; else [selection addIndex:(NSUInteger)row];
    [table selectRowIndexes:selection byExtendingSelection:NO];
  } else if (modifiers & NSEventModifierFlagShift) {
    NSInteger anchor = table.selectedRow >= 0 ? table.selectedRow : row;
    NSRange range = NSMakeRange((NSUInteger)MIN(anchor, row), (NSUInteger)labs(anchor - row) + 1);
    [table selectRowIndexes:[NSIndexSet indexSetWithIndexesInRange:range] byExtendingSelection:NO];
  } else if (!wasSelected) {
    [table selectRowIndexes:[NSIndexSet indexSetWithIndex:(NSUInteger)row] byExtendingSelection:NO];
  }
}

static NSArray<NSDictionary *> *FinderRelatedItems(NSDictionary *catalog) {
  NSMutableArray *items = [NSMutableArray array];
  for (NSDictionary *column in catalog[@"columns"] ?: @[]) {
    for (NSDictionary *record in column[@"records"] ?: @[]) {
      [items addObject:@{ @"kind": column[@"kind"] ?: @"", @"id": record[@"id"] ?: @"", @"title": record[@"title"] ?: record[@"id"] ?: @"", @"label": column[@"label"] ?: column[@"kind"] ?: @"", @"payload": record[@"payload"] ?: @"", @"preview": record[@"preview"] ?: @"" }];
    }
  }
  return items;
}

static NSColor *FinderGlassTint(BOOL inactive) {
  return [NSColor colorWithName:nil dynamicProvider:^NSColor *(NSAppearance *appearance) {
    NSAppearanceName match = [appearance bestMatchFromAppearancesWithNames:@[NSAppearanceNameAqua, NSAppearanceNameDarkAqua]];
    if ([match isEqualToString:NSAppearanceNameDarkAqua]) return [NSColor colorWithWhite:0 alpha:inactive ? 0.58 : 0.38];
    return [NSColor colorWithWhite:1 alpha:inactive ? 0.38 : 0.30];
  }];
}

static void FinderUpdateGlassTint(NSWindow *window) {
  if (@available(macOS 26.0, *)) {
    for (NSView *view in window.contentView.subviews) {
      if ([view isKindOfClass:NSGlassEffectView.class]) {
        ((NSGlassEffectView *)view).tintColor = FinderGlassTint(!NSApp.isActive);
        return;
      }
    }
  }
}

static void FinderUpdateAllGlassTints(void) {
  for (NSWindow *window in NSApp.windows) FinderUpdateGlassTint(window);
}

static NSWindowStyleMask FinderWindowStyle(void) {
  return NSWindowStyleMaskTitled | NSWindowStyleMaskClosable | NSWindowStyleMaskMiniaturizable | NSWindowStyleMaskResizable | NSWindowStyleMaskFullSizeContentView;
}

static void FinderConfigureWindow(NSWindow *window) {
  // Programmatically created windows default to releasedWhenClosed = YES, which
  // drops a phantom release that ARC's strong references don't know about: a
  // closed window is freed while its controller still points at it, and the
  // next FSEvents refresh messages the dangling pointer. Let ARC own lifetime.
  window.releasedWhenClosed = NO;
  window.titlebarAppearsTransparent = YES;
  window.titleVisibility = NSWindowTitleHidden;
  [window standardWindowButton:NSWindowCloseButton].hidden = YES;
  [window standardWindowButton:NSWindowMiniaturizeButton].hidden = YES;
  [window standardWindowButton:NSWindowZoomButton].hidden = YES;
}

@interface FinderDropView : NSView
@property(nonatomic, copy) BOOL (^onFileDrop)(NSArray<NSURL *> *urls);
@end

@implementation FinderDropView
- (instancetype)initWithFrame:(NSRect)frameRect {
  if (!(self = [super initWithFrame:frameRect])) return nil;
  [self registerForDraggedTypes:@[NSPasteboardTypeFileURL]];
  return self;
}
- (NSDragOperation)draggingEntered:(id<NSDraggingInfo>)sender { return FinderPayloadDropOperation(sender); }
- (BOOL)performDragOperation:(id<NSDraggingInfo>)sender {
  if (FinderDragIsInternal(sender)) return NO;
  return [self acceptFileDrop:FinderDroppedFileURLs(sender)];
}
- (BOOL)acceptFileDrop:(NSArray<NSURL *> *)urls { return urls.count && self.onFileDrop ? self.onFileDrop(urls) : NO; }
@end

static NSView *FinderWindowContent(NSWindow *window) {
  NSView *root = [[FinderDropView alloc] initWithFrame:window.contentView.bounds];
  root.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
  window.contentView = root;
  if (@available(macOS 26.0, *)) {
    NSGlassEffectView *glass = [[NSGlassEffectView alloc] initWithFrame:root.bounds];
    glass.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    glass.style = NSGlassEffectViewStyleRegular;
    glass.cornerRadius = 18;
    glass.tintColor = FinderGlassTint(!NSApp.isActive);
    [root addSubview:glass positioned:NSWindowBelow relativeTo:nil];
    window.backgroundColor = NSColor.clearColor;
    window.opaque = NO;
    return root;
  }
  window.backgroundColor = NSColor.windowBackgroundColor;
  window.opaque = YES;
  return root;
}

@interface FinderNativeTable : NSTableView
@property(nonatomic, weak) id<FinderPayloadDragOwner> owner;
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
@property(nonatomic) BOOL usesLiquidGlass;
@property(nonatomic, copy) void (^onClick)(void);
@end

@interface FinderRecordCell : NSTableCellView
@property(nonatomic) NSImageView *thumbnailView;
@property(nonatomic) NSTextField *titleView;
@property(nonatomic, copy) NSString *thumbnailPayload;
@property(nonatomic) QLThumbnailGenerationRequest *thumbnailRequest;
@end

@interface FinderRecordRow : NSTableRowView
@end

@interface FinderThumbnailManager : NSObject
@property(nonatomic) NSCache<NSString *, NSImage *> *cache;
+ (instancetype)shared;
- (void)loadPayload:(NSString *)payload intoCell:(FinderRecordCell *)cell scale:(CGFloat)scale;
@end

@interface FinderRelatedController : NSObject <NSWindowDelegate, NSTableViewDataSource, NSTableViewDelegate, FinderPayloadDragOwner>
@property(nonatomic) NSWindow *window;
@property(nonatomic) NSTableView *table;
@property(nonatomic) NSScrollView *scroll;
@property(nonatomic) FinderDragHeader *header;
@property(nonatomic) NSArray *items;
@property(nonatomic, copy) NSArray<NSString *> *seedIDs;
@property(nonatomic) BOOL directOnly;
- (instancetype)initWithCatalog:(NSDictionary *)catalog parent:(NSWindow *)parent seedIDs:(NSArray<NSString *> *)seedIDs directOnly:(BOOL)directOnly;
- (void)refreshFromDatabase;
- (void)openSelected;
- (void)quickLookSelected;
- (void)actOnSelected:(NSString *)action;
- (void)copyPayloadFilesToPasteboard;
- (NSMenu *)contextMenuForRow:(NSInteger)row;
@end

@interface FinderRelatedTable : NSTableView
@property(nonatomic, weak) FinderRelatedController *owner;
@end

@interface FinderNativeController : NSObject <NSApplicationDelegate, NSWindowDelegate, NSTableViewDataSource, NSTableViewDelegate, FinderPayloadDragOwner>
@property(nonatomic) NSWindow *window;
@property(nonatomic) FinderNativeTable *table;
@property(nonatomic) NSScrollView *scroll;
@property(nonatomic) NSArray *columns;
@property(nonatomic) NSArray *records;
@property(nonatomic) NSString *activeKind;
@property(nonatomic) FinderDragHeader *header;
@property(nonatomic) NSMutableArray *relatedControllers;
@property(nonatomic) FSEventStreamRef databaseEvents;
@property(nonatomic) BOOL catalogRefreshScheduled;
- (void)setupMainWindow;
- (void)importDroppedFiles:(NSArray<NSURL *> *)urls fromWindow:(NSWindow *)window;
- (void)scheduleCatalogRefresh;
- (void)refreshCatalogPreservingState;
@end

@implementation FinderNativeTable
- (void)mouseDown:(NSEvent *)event {
  NSEventModifierFlags modifiers = event.modifierFlags;
  BOOL openOriginal = (modifiers & NSEventModifierFlagOption) != 0;
  BOOL extendSelection = (modifiers & (NSEventModifierFlagCommand | NSEventModifierFlagShift | NSEventModifierFlagControl)) != 0;
  NSInteger clickedRow = [self rowAtPoint:[self convertPoint:event.locationInWindow fromView:nil]];
  BOOL wasSelected = clickedRow >= 0 && [self.selectedRowIndexes containsIndex:(NSUInteger)clickedRow];
  if (clickedRow < 0) { [super mouseDown:event]; return; }
  if (openOriginal && wasSelected) {
    [(FinderNativeController *)self.owner performSelector:@selector(open:) withObject:nil];
    return;
  }
  FinderSelectRow(self, clickedRow, modifiers, wasSelected);
  if (self.selectedRow < 0) return;
  FinderNativeController *controller = (FinderNativeController *)self.owner;
  if (openOriginal) [controller performSelector:@selector(open:) withObject:nil];
  if (openOriginal) return;
  while (YES) {
    NSEvent *next = [self.window nextEventMatchingMask:NSEventMaskLeftMouseUp | NSEventMaskLeftMouseDragged];
    if (next.type == NSEventTypeLeftMouseDragged) {
      [self.owner beginPayloadDragFromTable:self event:event];
      return;
    }
    if (next.type == NSEventTypeLeftMouseUp) {
      if (!extendSelection && wasSelected) [controller performSelector:@selector(quickLook:) withObject:nil];
      return;
    }
  }
}
- (void)updateTrackingAreas {
  [super updateTrackingAreas];
  [self addTrackingArea:[[NSTrackingArea alloc] initWithRect:self.bounds options:NSTrackingMouseMoved | NSTrackingActiveInKeyWindow | NSTrackingInVisibleRect owner:self userInfo:nil]];
}
- (void)mouseMoved:(NSEvent *)event { self.hoveredRow = [self rowAtPoint:[self convertPoint:event.locationInWindow fromView:nil]]; }
- (NSDragOperation)draggingSession:(NSDraggingSession *)session sourceOperationMaskForDraggingContext:(NSDraggingContext)context { return NSDragOperationCopy; }
- (NSDragOperation)draggingEntered:(id<NSDraggingInfo>)sender { return FinderPayloadDropOperation(sender); }
- (BOOL)performDragOperation:(id<NSDraggingInfo>)sender { if (FinderDragIsInternal(sender)) return NO; return [(id)self.window.contentView acceptFileDrop:FinderDroppedFileURLs(sender)]; }
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
  self.titleLabel.frame = NSMakeRect(20, 8, 260, 20);
  self.titleLabel.font = [NSFont systemFontOfSize:14 weight:NSFontWeightSemibold];
  self.titleLabel.textColor = NSColor.labelColor;
  self.titleLabel.autoresizingMask = NSViewWidthSizable;
  [self addSubview:self.titleLabel];
  return self;
}
- (void)drawRect:(NSRect)dirtyRect {
  [super drawRect:dirtyRect];
  if (!self.usesLiquidGlass) {
    [NSColor.controlBackgroundColor setFill];
    NSRectFill(self.bounds);
    [NSColor.separatorColor setFill];
    NSRectFill(NSMakeRect(0, 0, self.bounds.size.width, 1));
  }
}
- (void)mouseDown:(NSEvent *)event { self.startMouse = NSEvent.mouseLocation; self.startFrame = self.window.frame; }
- (void)mouseDragged:(NSEvent *)event {
  NSPoint now = NSEvent.mouseLocation;
  NSRect frame = self.startFrame;
  frame.origin.x += now.x - self.startMouse.x;
  frame.origin.y += now.y - self.startMouse.y;
  [self.window setFrameOrigin:frame.origin];
}
- (void)mouseUp:(NSEvent *)event {
  NSPoint now = NSEvent.mouseLocation;
  if (self.onClick && hypot(now.x - self.startMouse.x, now.y - self.startMouse.y) < 4.0) self.onClick();
}
@end

@implementation FinderRecordRow
- (void)drawSelectionInRect:(NSRect)dirtyRect {
  if (self.window.isKeyWindow && NSApp.isActive) [super drawSelectionInRect:dirtyRect];
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
- (instancetype)initWithCatalog:(NSDictionary *)catalog parent:(NSWindow *)parent seedIDs:(NSArray<NSString *> *)seedIDs directOnly:(BOOL)directOnly {
  if (!(self = [super init])) return nil;
  self.seedIDs = seedIDs;
  self.directOnly = directOnly;
  self.items = FinderRelatedItems(catalog);
  self.window = [[NSWindow alloc] initWithContentRect:NSMakeRect(parent.frame.origin.x + 28, parent.frame.origin.y + 28, 300, 360) styleMask:FinderWindowStyle() backing:NSBackingStoreBuffered defer:NO];
  FinderConfigureWindow(self.window);
  self.window.delegate = self;
  self.window.movableByWindowBackground = YES; self.window.hasShadow = YES; self.window.minSize = NSMakeSize(180, 140);
  NSView *content = FinderWindowContent(self.window);
  __weak NSWindow *weakWindow = self.window;
  ((FinderDropView *)content).onFileDrop = ^BOOL(NSArray<NSURL *> *urls) {
    FinderNativeController *controller = (FinderNativeController *)NSApp.delegate;
    [controller importDroppedFiles:urls fromWindow:weakWindow ?: controller.window];
    return YES;
  };
  self.header = [[FinderDragHeader alloc] initWithFrame:NSMakeRect(0, 324, 300, FinderHeaderHeight)];
  if (@available(macOS 26.0, *)) self.header.usesLiquidGlass = YES;
  self.header.autoresizingMask = NSViewWidthSizable | NSViewMinYMargin;
  __weak FinderRelatedController *weakSelf = self;
  self.header.onClick = ^{ [weakSelf.table deselectAll:nil]; };
  self.header.titleLabel.stringValue = catalog[@"header"] ?: @"Links";
  [content addSubview:self.header];
  self.scroll = [[NSScrollView alloc] initWithFrame:NSMakeRect(0, 0, 300, 324)];
  self.scroll.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable; self.scroll.hasVerticalScroller = YES; self.scroll.borderType = NSNoBorder; self.scroll.drawsBackground = NO;
  self.table = [[FinderRelatedTable alloc] initWithFrame:self.scroll.bounds];
  ((FinderRelatedTable *)self.table).owner = self; self.table.headerView = nil; self.table.allowsMultipleSelection = YES; self.table.allowsEmptySelection = YES;
  [self.table registerForDraggedTypes:@[NSPasteboardTypeFileURL]];
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
- (void)refreshFromDatabase {
  if (!self.window.isVisible || !self.seedIDs.count) return;
  NSMutableSet<NSString *> *selected = [NSMutableSet set];
  [self.table.selectedRowIndexes enumerateIndexesUsingBlock:^(NSUInteger row, BOOL *stop) {
    (void)stop;
    NSDictionary *item = self.items[row];
    [selected addObject:[NSString stringWithFormat:@"%@/%@", item[@"kind"], item[@"id"]]];
  }];
  NSData *seedData = [NSJSONSerialization dataWithJSONObject:self.seedIDs options:0 error:nil];
  NSString *seedJSON = [[NSString alloc] initWithData:seedData encoding:NSUTF8StringEncoding] ?: @"[]";
  char *raw = finder_native_related_json(seedJSON.UTF8String, self.directOnly);
  NSData *data = raw ? [NSData dataWithBytes:raw length:strlen(raw)] : nil;
  if (raw) finder_native_free_string(raw);
  NSDictionary *catalog = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
  if (!catalog || catalog[@"error"]) return;
  self.items = FinderRelatedItems(catalog);
  self.header.titleLabel.stringValue = catalog[@"header"] ?: @"Links";
  self.window.title = catalog[@"title"] ?: @"Links";
  [self.table reloadData];
  NSMutableIndexSet *rows = [NSMutableIndexSet indexSet];
  [self.items enumerateObjectsUsingBlock:^(NSDictionary *item, NSUInteger index, BOOL *stop) {
    (void)stop;
    if ([selected containsObject:[NSString stringWithFormat:@"%@/%@", item[@"kind"], item[@"id"]]]) [rows addIndex:index];
  }];
  [self.table selectRowIndexes:rows byExtendingSelection:NO];
}
- (NSInteger)numberOfRowsInTableView:(NSTableView *)table { return self.items.count; }
- (NSDragOperation)tableView:(NSTableView *)tableView validateDrop:(id<NSDraggingInfo>)info proposedRow:(NSInteger)row proposedDropOperation:(NSTableViewDropOperation)dropOperation {
  [tableView setDropRow:-1 dropOperation:NSTableViewDropOn];
  return FinderPayloadDropOperation(info);
}
- (BOOL)tableView:(NSTableView *)tableView acceptDrop:(id<NSDraggingInfo>)info row:(NSInteger)row dropOperation:(NSTableViewDropOperation)dropOperation {
  if (FinderDragIsInternal(info)) return NO;
  return [(id)tableView.window.contentView acceptFileDrop:FinderDroppedFileURLs(info)];
}
- (NSTableRowView *)tableView:(NSTableView *)tableView rowViewForRow:(NSInteger)row {
  return [[FinderRecordRow alloc] initWithFrame:NSZeroRect];
}
- (NSView *)tableView:(NSTableView *)table viewForTableColumn:(NSTableColumn *)column row:(NSInteger)row {
  FinderRecordCell *cell = [table makeViewWithIdentifier:@"related-cell" owner:self];
  if (!cell) { cell = [[FinderRecordCell alloc] initWithFrame:NSMakeRect(0, 0, table.bounds.size.width, 34)]; cell.identifier = @"related-cell"; }
  NSDictionary *item = self.items[(NSUInteger)row];
  cell.titleView.stringValue = [NSString stringWithFormat:@"%@  %@", item[@"label"], item[@"title"]];
  [cell setNeedsLayout:YES];
  NSString *preview = item[@"preview"];
  [[FinderThumbnailManager shared] loadPayload:preview.length ? preview : item[@"payload"] intoCell:cell scale:self.window.backingScaleFactor ?: 1.0];
  return cell;
}
- (void)openSelected {
  [self actOnSelected:@"open"];
}
- (void)beginPayloadDragFromTable:(NSTableView *)table event:(NSEvent *)event {
  NSMutableDictionary<NSString *, NSMutableArray<NSString *> *> *idsByKind = [NSMutableDictionary dictionary];
  [table.selectedRowIndexes enumerateIndexesUsingBlock:^(NSUInteger row, BOOL *stop) {
    (void)stop;
    NSDictionary *item = self.items[row];
    NSString *kind = item[@"kind"];
    NSString *recordId = item[@"id"];
    if (!kind.length || !recordId.length) return;
    if (!idsByKind[kind]) idsByKind[kind] = [NSMutableArray array];
    [idsByKind[kind] addObject:recordId];
  }];
  NSMutableArray<NSURL *> *urls = [NSMutableArray array];
  for (NSString *kind in idsByKind) [urls addObjectsFromArray:FinderPayloadURLs(kind, idsByKind[kind])];
  FinderBeginPayloadDrag(table, event, urls);
}
- (void)windowDidBecomeKey:(NSNotification *)notification { lastKeyWindow = self.window; }
- (void)windowWillClose:(NSNotification *)notification {
  if (lastKeyWindow == self.window) lastKeyWindow = nil;
  FinderNativeController *app = (FinderNativeController *)NSApp.delegate;
  dispatch_async(dispatch_get_main_queue(), ^{ [app.relatedControllers removeObject:self]; });
}
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
- (void)copyPayloadFilesToPasteboard {
  NSMutableArray<NSString *> *ids = [NSMutableArray array];
  [self.table.selectedRowIndexes enumerateIndexesUsingBlock:^(NSUInteger row, BOOL *stop) {
    (void)stop;
    NSString *recordId = self.items[row][@"id"];
    if (recordId.length) [ids addObject:recordId];
  }];
  FinderCopyPayloadFiles(ids);
}
- (NSMenu *)contextMenuForRow:(NSInteger)row {
  if (row < 0 || (NSUInteger)row >= self.items.count) return nil;
  NSDictionary *item = self.items[(NSUInteger)row];
  NSMenu *menu = [[NSMenu alloc] init];
  NSMenuItem *remove = [menu addItemWithTitle:@"Remove Link" action:@selector(removeLinkForContextRow:) keyEquivalent:@""];
  remove.target = self;
  remove.representedObject = item[@"id"];
  return menu;
}
- (void)removeLinkForContextRow:(NSMenuItem *)sender {
  NSString *targetID = sender.representedObject;
  if (!targetID.length || !self.seedIDs.count) return;
  NSDictionary *item = nil;
  for (NSDictionary *candidate in self.items) {
    if ([candidate[@"id"] isEqualToString:targetID]) { item = candidate; break; }
  }
  NSString *title = [item[@"title"] length] ? item[@"title"] : targetID;
  NSAlert *alert = [[NSAlert alloc] init];
  alert.messageText = @"Remove link?";
  alert.informativeText = [NSString stringWithFormat:
      @"This removes the direct link between the source record%@ and “%@”. The records themselves are not deleted.",
      self.seedIDs.count > 1 ? @"s" : @"", title];
  [alert addButtonWithTitle:@"Remove"];
  [alert addButtonWithTitle:@"Cancel"];
  if ([alert runModal] != NSAlertFirstButtonReturn) return;
  NSData *seedData = [NSJSONSerialization dataWithJSONObject:self.seedIDs options:0 error:nil];
  NSString *seedJSON = [[NSString alloc] initWithData:seedData encoding:NSUTF8StringEncoding] ?: @"[]";
  int removed = finder_native_unlink(seedJSON.UTF8String, targetID.UTF8String);
  if (removed > 0) {
    FinderNativeController *app = (FinderNativeController *)NSApp.delegate;
    [app refreshCatalogPreservingState];
    return;
  }
  NSAlert *note = [[NSAlert alloc] init];
  note.messageText = removed == 0 ? @"No direct link to remove" : @"Could not remove link";
  note.informativeText = removed == 0
      ? @"This record is not linked directly from the source record; it appears here through another record."
      : @"The metadata could not be updated. See the console for details.";
  [note addButtonWithTitle:@"OK"];
  [note runModal];
}
@end

@implementation FinderRelatedTable
- (void)mouseDown:(NSEvent *)event {
  NSEventModifierFlags modifiers = event.modifierFlags;
  BOOL openOriginal = (modifiers & NSEventModifierFlagOption) != 0;
  BOOL extendSelection = (modifiers & (NSEventModifierFlagCommand | NSEventModifierFlagShift | NSEventModifierFlagControl)) != 0;
  NSInteger clickedRow = [self rowAtPoint:[self convertPoint:event.locationInWindow fromView:nil]];
  BOOL wasSelected = clickedRow >= 0 && [self.selectedRowIndexes containsIndex:(NSUInteger)clickedRow];
  if (clickedRow < 0) { [super mouseDown:event]; return; }
  if (openOriginal && wasSelected) { [self.owner openSelected]; return; }
  FinderSelectRow(self, clickedRow, modifiers, wasSelected);
  if (self.selectedRow < 0) return;
  if (openOriginal) { [self.owner openSelected]; return; }
  while (YES) {
    NSEvent *next = [self.window nextEventMatchingMask:NSEventMaskLeftMouseUp | NSEventMaskLeftMouseDragged];
    if (next.type == NSEventTypeLeftMouseDragged) {
      [self.owner beginPayloadDragFromTable:self event:event];
      return;
    }
    if (next.type == NSEventTypeLeftMouseUp) {
      if (!extendSelection && wasSelected) [self.owner quickLookSelected];
      return;
    }
  }
}
- (NSMenu *)menuForEvent:(NSEvent *)event {
  NSInteger row = [self rowAtPoint:[self convertPoint:event.locationInWindow fromView:nil]];
  if (row < 0) return nil;
  if (![self.selectedRowIndexes containsIndex:(NSUInteger)row])
    [self selectRowIndexes:[NSIndexSet indexSetWithIndex:(NSUInteger)row] byExtendingSelection:NO];
  return [self.owner contextMenuForRow:row];
}
- (NSDragOperation)draggingSession:(NSDraggingSession *)session sourceOperationMaskForDraggingContext:(NSDraggingContext)context { return NSDragOperationCopy; }
- (NSDragOperation)draggingEntered:(id<NSDraggingInfo>)sender { return FinderPayloadDropOperation(sender); }
- (BOOL)performDragOperation:(id<NSDraggingInfo>)sender { if (FinderDragIsInternal(sender)) return NO; return [(id)self.window.contentView acceptFileDrop:FinderDroppedFileURLs(sender)]; }
@end

static void FinderDatabaseEvents(
    ConstFSEventStreamRef streamRef,
    void *clientCallBackInfo,
    size_t numEvents,
    void *eventPaths,
    const FSEventStreamEventFlags eventFlags[],
    const FSEventStreamEventId eventIds[]
) {
  (void)streamRef; (void)numEvents; (void)eventPaths; (void)eventFlags; (void)eventIds;
  FinderNativeController *controller = (__bridge FinderNativeController *)clientCallBackInfo;
  [controller scheduleCatalogRefresh];
}

@implementation FinderNativeController

- (void)applicationDidFinishLaunching:(NSNotification *)note { [self setupMainWindow]; }
- (void)applicationDidBecomeActive:(NSNotification *)note { FinderUpdateAllGlassTints(); }
- (void)applicationDidResignActive:(NSNotification *)note { FinderUpdateAllGlassTints(); }

- (void)setupMainWindow {
  NSRect frame = NSMakeRect(0, 0, 300, 420);
  self.window = [[NSWindow alloc] initWithContentRect:frame styleMask:FinderWindowStyle() backing:NSBackingStoreBuffered defer:NO];
  FinderConfigureWindow(self.window);
  self.window.movableByWindowBackground = YES;
  self.window.delegate = self;
  self.window.hasShadow = YES;
  self.window.minSize = NSMakeSize(180, 140);
  [self.window center];
  NSView *content = FinderWindowContent(self.window);
  __weak FinderNativeController *weakSelf = self;
  ((FinderDropView *)content).onFileDrop = ^BOOL(NSArray<NSURL *> *urls) {
    FinderNativeController *controller = weakSelf;
    if (!controller) return NO;
    [controller importDroppedFiles:urls fromWindow:controller.window];
    return YES;
  };

  self.header = [[FinderDragHeader alloc] initWithFrame:NSMakeRect(0, 384, 300, FinderHeaderHeight)];
  if (@available(macOS 26.0, *)) self.header.usesLiquidGlass = YES;
  self.header.autoresizingMask = NSViewWidthSizable | NSViewMinYMargin;
  self.header.onClick = ^{ [weakSelf.table deselectAll:nil]; };
  [content addSubview:self.header];
  self.scroll = [[NSScrollView alloc] initWithFrame:NSMakeRect(0, 0, 300, 384)];
  self.scroll.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
  self.scroll.hasVerticalScroller = YES;
  self.scroll.borderType = NSNoBorder;
  self.scroll.drawsBackground = NO;
  self.table = [[FinderNativeTable alloc] initWithFrame:self.scroll.bounds];
  self.table.owner = self;
  self.table.hoveredRow = -1;
  self.relatedControllers = [NSMutableArray array];
  self.table.headerView = nil;
  self.table.allowsMultipleSelection = YES;
  self.table.allowsEmptySelection = YES;
  [self.table registerForDraggedTypes:@[NSPasteboardTypeFileURL]];
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
  [self startWatchingDatabase];
  [self.window makeKeyAndOrderFront:nil];
  [NSApp activateIgnoringOtherApps:YES];
}

- (void)dealloc {
  if (self.databaseEvents) {
    FSEventStreamStop(self.databaseEvents);
    FSEventStreamInvalidate(self.databaseEvents);
    FSEventStreamRelease(self.databaseEvents);
  }
}

- (void)startWatchingDatabase {
  char *raw = finder_native_db_root();
  NSString *root = raw ? [[NSString alloc] initWithUTF8String:raw] : nil;
  if (raw) finder_native_free_string(raw);
  if (!root.length) return;
  FSEventStreamContext context = {0, (__bridge void *)self, NULL, NULL, NULL};
  self.databaseEvents = FSEventStreamCreate(
      NULL,
      FinderDatabaseEvents,
      &context,
      (__bridge CFArrayRef)@[root],
      kFSEventStreamEventIdSinceNow,
      0.2,
      kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagNoDefer
  );
  if (!self.databaseEvents) return;
  FSEventStreamSetDispatchQueue(self.databaseEvents, dispatch_get_main_queue());
  if (!FSEventStreamStart(self.databaseEvents)) {
    FSEventStreamInvalidate(self.databaseEvents);
    FSEventStreamRelease(self.databaseEvents);
    self.databaseEvents = NULL;
  }
}

- (void)scheduleCatalogRefresh {
  if (self.catalogRefreshScheduled) return;
  self.catalogRefreshScheduled = YES;
  __weak FinderNativeController *weakSelf = self;
  dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.3 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
    FinderNativeController *controller = weakSelf;
    if (!controller) return;
    controller.catalogRefreshScheduled = NO;
    [controller refreshCatalogPreservingState];
  });
}

- (void)refreshCatalogPreservingState {
  NSString *kind = self.activeKind;
  NSArray<NSString *> *ids = self.selectedIds;
  [self loadCatalogPreferringKind:kind selectedIDs:ids];
  [self installMenu];
  for (FinderRelatedController *controller in self.relatedControllers.copy) [controller refreshFromDatabase];
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
  NSMenuItem *keepInFront = [file addItemWithTitle:@"Keep in Front" action:@selector(toggleKeepInFront:) keyEquivalent:@"t"];
  keepInFront.target = self;
  [file addItem:[NSMenuItem separatorItem]];
  [file addItemWithTitle:@"Open Metadata" action:@selector(metadata:) keyEquivalent:@"j"];
  NSMenuItem *rename = [file addItemWithTitle:@"Rename" action:@selector(renameSelected:) keyEquivalent:@"\r"];
  rename.target = self;
  [file addItemWithTitle:@"Reveal in Finder" action:@selector(reveal:) keyEquivalent:@"f"];
  NSMenuItem *openQuickLook = [file addItemWithTitle:@"Open Quick Look Original" action:@selector(openQuickLookOriginal:) keyEquivalent:@"o"];
  openQuickLook.target = self;
  NSMenuItem *copyFiles = [file addItemWithTitle:@"Copy" action:@selector(copyPayloadFiles:) keyEquivalent:@"c"];
  copyFiles.target = self;
  NSMenuItem *copyRelativePath = [file addItemWithTitle:@"Copy Relative Path" action:@selector(copyRelative:) keyEquivalent:@"p"];
  copyRelativePath.target = self;
  NSMenuItem *copyPath = [file addItemWithTitle:@"Copy Full Path" action:@selector(copy:) keyEquivalent:@"p"];
  copyPath.keyEquivalentModifierMask = NSEventModifierFlagCommand | NSEventModifierFlagOption;
  copyPath.target = self;
  fileItem.submenu = file; NSApp.mainMenu = bar;
  NSMenuItem *linkItem = [NSMenuItem new]; [bar addItem:linkItem];
  NSMenu *link = [[NSMenu alloc] initWithTitle:@"Link"];
  NSMenuItem *related = [link addItemWithTitle:@"Open Related" action:@selector(openRelated:) keyEquivalent:@"e"];
  related.keyEquivalentModifierMask = NSEventModifierFlagCommand;
  related.target = self;
  NSMenuItem *relatedDirect = [link addItemWithTitle:@"Open Direct Links" action:@selector(openRelatedDirect:) keyEquivalent:@"e"];
  relatedDirect.keyEquivalentModifierMask = NSEventModifierFlagCommand | NSEventModifierFlagOption;
  relatedDirect.target = self;
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
  [self loadCatalogPreferringKind:nil selectedIDs:@[]];
}

- (void)loadCatalogPreferringKind:(NSString *)preferredKind selectedIDs:(NSArray<NSString *> *)selectedIDs {
  char *raw = finder_native_catalog_json();
  NSData *data = raw ? [NSData dataWithBytes:raw length:strlen(raw)] : nil;
  if (raw) finder_native_free_string(raw);
  NSDictionary *catalog = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
  self.columns = catalog[@"columns"] ?: @[];
  if (!self.columns.count) { self.records = @[]; [self.table reloadData]; return; }
  NSUInteger index = [self.columns indexOfObjectPassingTest:^BOOL(NSDictionary *column, NSUInteger idx, BOOL *stop) {
    (void)idx; (void)stop;
    return [column[@"kind"] isEqualToString:preferredKind];
  }];
  [self chooseColumn:index == NSNotFound ? 0 : (NSInteger)index];
  if (!selectedIDs.count) return;
  NSMutableSet<NSString *> *wanted = [NSMutableSet setWithArray:selectedIDs];
  NSMutableIndexSet *rows = [NSMutableIndexSet indexSet];
  [self.records enumerateObjectsUsingBlock:^(NSDictionary *record, NSUInteger row, BOOL *stop) {
    (void)stop;
    if ([wanted containsObject:record[@"id"]]) [rows addIndex:row];
  }];
  [self.table selectRowIndexes:rows byExtendingSelection:NO];
}

- (void)importDroppedFiles:(NSArray<NSURL *> *)urls fromWindow:(NSWindow *)window {
  if (!urls.count || !self.columns.count) return;
  NSAlert *alert = [NSAlert new];
  alert.messageText = @"Add Record";
  alert.informativeText = [NSString stringWithFormat:@"%ld payload%@", urls.count, urls.count == 1 ? @"" : @"s"];
  NSView *form = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 320, 68)];
  NSTextField *categoryLabel = [NSTextField labelWithString:@"Category"];
  categoryLabel.frame = NSMakeRect(0, 43, 98, 20);
  [form addSubview:categoryLabel];
  NSPopUpButton *category = [[NSPopUpButton alloc] initWithFrame:NSMakeRect(104, 39, 216, 26) pullsDown:NO];
  for (NSDictionary *column in self.columns) {
    [category addItemWithTitle:column[@"label"] ?: column[@"kind"] ?: @""];
    category.lastItem.representedObject = column[@"kind"] ?: @"";
  }
  [form addSubview:category];
  NSTextField *nameLabel = [NSTextField labelWithString:@"Display name"];
  nameLabel.frame = NSMakeRect(0, 8, 98, 20);
  [form addSubview:nameLabel];
  NSTextField *name = [[NSTextField alloc] initWithFrame:NSMakeRect(104, 4, 216, 24)];
  name.placeholderString = @"Display name";
  if (urls.count == 1) name.stringValue = urls.firstObject.lastPathComponent.stringByDeletingPathExtension;
  [form addSubview:name];
  alert.accessoryView = form;
  [alert addButtonWithTitle:@"Add"];
  [alert addButtonWithTitle:@"Cancel"];
  [alert beginSheetModalForWindow:window completionHandler:^(NSModalResponse response) {
    if (response != NSAlertFirstButtonReturn) return;
    NSString *kind = category.selectedItem.representedObject ?: @"";
    NSString *displayName = [name.stringValue stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    NSMutableArray<NSString *> *paths = [NSMutableArray arrayWithCapacity:urls.count];
    for (NSURL *url in urls) if (url.isFileURL && url.path.length) [paths addObject:url.path];
    NSData *request = [NSJSONSerialization dataWithJSONObject:paths options:0 error:nil];
    NSString *json = [[NSString alloc] initWithData:request encoding:NSUTF8StringEncoding];
    char *raw = json ? finder_native_create_record(kind.UTF8String, displayName.UTF8String, json.UTF8String) : NULL;
    NSData *data = raw ? [NSData dataWithBytes:raw length:strlen(raw)] : nil;
    if (raw) finder_native_free_string(raw);
    NSDictionary *result = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
    if (result[@"error"] || !result[@"id"]) {
      NSAlert *error = [NSAlert new];
      error.messageText = @"Could not add record";
      error.informativeText = result[@"error"] ?: @"Unknown error";
      [error beginSheetModalForWindow:window completionHandler:nil];
      return;
    }
    [self loadCatalog];
    NSUInteger columnIndex = [self.columns indexOfObjectPassingTest:^BOOL(NSDictionary *column, NSUInteger index, BOOL *stop) {
      (void)index; (void)stop;
      return [column[@"kind"] isEqualToString:kind];
    }];
    if (columnIndex != NSNotFound) {
      [self chooseColumn:(NSInteger)columnIndex];
      NSUInteger row = [self.records indexOfObjectPassingTest:^BOOL(NSDictionary *record, NSUInteger index, BOOL *stop) {
        (void)index; (void)stop;
        return [record[@"id"] isEqualToString:result[@"id"]];
      }];
      if (row != NSNotFound) [self.table selectRowIndexes:[NSIndexSet indexSetWithIndex:row] byExtendingSelection:NO];
    }
  }];
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
- (NSDragOperation)tableView:(NSTableView *)tableView validateDrop:(id<NSDraggingInfo>)info proposedRow:(NSInteger)row proposedDropOperation:(NSTableViewDropOperation)dropOperation {
  [tableView setDropRow:-1 dropOperation:NSTableViewDropOn];
  return FinderPayloadDropOperation(info);
}
- (BOOL)tableView:(NSTableView *)tableView acceptDrop:(id<NSDraggingInfo>)info row:(NSInteger)row dropOperation:(NSTableViewDropOperation)dropOperation {
  if (FinderDragIsInternal(info)) return NO;
  return [(id)tableView.window.contentView acceptFileDrop:FinderDroppedFileURLs(info)];
}
- (NSTableRowView *)tableView:(NSTableView *)tableView rowViewForRow:(NSInteger)row {
  return [[FinderRecordRow alloc] initWithFrame:NSZeroRect];
}
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
- (void)beginPayloadDragFromTable:(NSTableView *)table event:(NSEvent *)event {
  FinderBeginPayloadDrag(table, event, FinderPayloadURLs(self.kind, self.selectedIds));
}
- (void)act:(NSString *)action {
  NSArray *ids = self.selectedIds; if (!ids.count && ![action isEqual:@"reveal"] && ![action isEqual:@"copy"] && ![action isEqual:@"copy-relative"]) return;
  NSData *data = [NSJSONSerialization dataWithJSONObject:ids options:0 error:nil];
  NSString *json = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] ?: @"[]";
  finder_native_action(self.kind.UTF8String, json.UTF8String, action.UTF8String);
}
// Menu items are hard-targeted at this controller, so a menu command issued
// while a Links window is key must be forwarded to that window's controller.
- (FinderRelatedController *)keyRelatedController {
  NSWindow *key = NSApp.keyWindow ?: lastKeyWindow;
  if (!key || key == self.window) return nil;
  for (FinderRelatedController *controller in self.relatedControllers)
    if (controller.window == key) return controller;
  return nil;
}
- (void)routeAction:(NSString *)action {
  FinderRelatedController *related = [self keyRelatedController];
  if (related) { [related actOnSelected:action]; return; }
  [self act:action];
}
- (void)tableView:(NSTableView *)tableView didDoubleClickRow:(NSInteger)row { [self act:@"open"]; }
- (void)quickLook:(id)sender {
  FinderRelatedController *related = [self keyRelatedController];
  if (related) { [related quickLookSelected]; return; }
  [self act:@"quicklook"];
}
- (void)open:(id)sender { [self routeAction:@"open"]; }
- (void)metadata:(id)sender { [self routeAction:@"metadata"]; }
- (void)reveal:(id)sender { [self routeAction:@"reveal"]; }
- (void)copy:(id)sender { [self routeAction:@"copy"]; }
- (void)copyRelative:(id)sender { [self routeAction:@"copy-relative"]; }
- (void)copyPayloadFiles:(id)sender {
  FinderRelatedController *related = [self keyRelatedController];
  if (related) { [related copyPayloadFilesToPasteboard]; return; }
  FinderCopyPayloadFiles(self.selectedIds);   // ids ignored by Rust while Quick Look is up
}
- (void)openQuickLookOriginal:(id)sender { finder_native_action(self.kind.UTF8String, "[]", "open-ql"); }
- (void)closeWindow:(id)sender {
  NSWindow *window = NSApp.orderedWindows.firstObject ?: lastKeyWindow ?: self.window;
  lastKeyWindow = nil;
  [window close];
}
- (void)toggleKeepInFront:(id)sender {
  NSWindow *window = NSApp.keyWindow ?: lastKeyWindow ?: self.window;
  window.level = window.level == NSFloatingWindowLevel ? NSNormalWindowLevel : NSFloatingWindowLevel;
}
- (void)renameSelected:(id)sender {
  FinderRelatedController *related = [self keyRelatedController];
  NSTableView *table = related ? related.table : self.table;
  NSArray *rows = related ? related.items : self.records;
  if (table.selectedRowIndexes.count != 1) return;
  NSDictionary *record = rows[(NSUInteger)table.selectedRow];
  NSString *kind = related ? record[@"kind"] : self.kind;
  if (!kind.length || !record[@"id"]) return;
  NSAlert *alert = [NSAlert new]; alert.messageText = @"Rename"; alert.informativeText = @"Display name";
  NSTextField *field = [[NSTextField alloc] initWithFrame:NSMakeRect(0, 0, 260, 24)]; field.stringValue = record[@"title"] ?: record[@"id"] ?: @""; alert.accessoryView = field;
  [alert addButtonWithTitle:@"Rename"]; [alert addButtonWithTitle:@"Cancel"];
  if ([alert runModal] != NSAlertFirstButtonReturn) return;
  if (finder_native_rename(kind.UTF8String, [record[@"id"] UTF8String], field.stringValue.UTF8String)) [self refreshCatalogPreservingState];
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
- (void)openRelatedForIDs:(NSArray<NSString *> *)ids parent:(NSWindow *)parent directOnly:(BOOL)directOnly {
  NSMutableArray<NSString *> *seeds = [NSMutableArray array];
  for (NSString *seed in ids) if (seed.length) [seeds addObject:seed];
  if (!seeds.count) return;
  NSData *seedData = [NSJSONSerialization dataWithJSONObject:seeds options:0 error:nil];
  NSString *seedJSON = [[NSString alloc] initWithData:seedData encoding:NSUTF8StringEncoding] ?: @"[]";
  char *raw = finder_native_related_json(seedJSON.UTF8String, directOnly);
  NSData *data = raw ? [NSData dataWithBytes:raw length:strlen(raw)] : nil; if (raw) finder_native_free_string(raw);
  NSDictionary *catalog = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil; if (!catalog || catalog[@"error"]) return;
  FinderRelatedController *controller = [[FinderRelatedController alloc] initWithCatalog:catalog parent:parent seedIDs:seeds directOnly:directOnly]; [self.relatedControllers addObject:controller];
}
- (void)openRelatedWithDirectOnly:(BOOL)directOnly {
  FinderRelatedController *related = [self keyRelatedController];
  if (related) {
    NSMutableArray<NSString *> *ids = [NSMutableArray array];
    [related.table.selectedRowIndexes enumerateIndexesUsingBlock:^(NSUInteger row, BOOL *stop) {
      (void)stop; NSString *rid = related.items[row][@"id"]; if (rid.length) [ids addObject:rid];
    }];
    [self openRelatedForIDs:ids parent:related.window directOnly:directOnly];
    return;
  }
  if (NSApp.orderedWindows.firstObject != self.window) return;
  NSArray<NSString *> *ids = self.selectedIds;
  if (!ids.count && self.table.hoveredRow >= 0 && self.table.hoveredRow < (NSInteger)self.records.count) {
    NSString *rid = self.records[(NSUInteger)self.table.hoveredRow][@"id"];
    if (rid.length) ids = @[ rid ];
  }
  [self openRelatedForIDs:ids parent:self.window directOnly:directOnly];
}
- (void)openRelated:(id)sender { [self openRelatedWithDirectOnly:NO]; }
- (void)openRelatedDirect:(id)sender { [self openRelatedWithDirectOnly:YES]; }
- (BOOL)validateMenuItem:(NSMenuItem *)item {
  if (item.action == @selector(toggleKeepInFront:)) {
    NSWindow *window = NSApp.keyWindow ?: lastKeyWindow ?: self.window;
    item.state = window.level == NSFloatingWindowLevel ? NSControlStateValueOn : NSControlStateValueOff;
    return YES;
  }
  if (item.action == @selector(openRelated:) || item.action == @selector(openRelatedDirect:)) {
    FinderRelatedController *related = [self keyRelatedController];
    if (related) return related.table.selectedRow >= 0;
    return NSApp.orderedWindows.firstObject == self.window
        && (self.table.selectedRow >= 0 || self.table.hoveredRow >= 0);
  }
  if (item.action == @selector(copyPayloadFiles:)) {
    // Let a modal (the Rename dialog) keep Cmd-C for its text field.
    return NSApp.modalWindow == nil;
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
