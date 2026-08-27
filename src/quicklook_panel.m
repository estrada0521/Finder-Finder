#import <Cocoa/Cocoa.h>
#import <QuickLookUI/QuickLookUI.h>

@interface FinderQuickLookItem : NSObject <QLPreviewItem>
@property(nonatomic, copy) NSURL *url;
@property(nonatomic, copy) NSString *displayName;
@end

@implementation FinderQuickLookItem
- (NSURL *)previewItemURL { return self.url; }
- (NSString *)previewItemDisplayName { return self.displayName; }
@end

@interface FinderQuickLookDataSource : NSObject <QLPreviewPanelDataSource>
@property(nonatomic, copy) NSArray<FinderQuickLookItem *> *items;
@end

@implementation FinderQuickLookDataSource

- (NSInteger)numberOfPreviewItemsInPreviewPanel:(QLPreviewPanel *)panel {
  return self.items.count;
}

- (id<QLPreviewItem>)previewPanel:(QLPreviewPanel *)panel previewItemAtIndex:(NSInteger)index {
  if (index < 0 || (NSUInteger)index >= self.items.count) return nil;
  return self.items[(NSUInteger)index];
}

@end

static FinderQuickLookDataSource *dataSource;

void finder_quicklook_open(const char *const *paths, const char *const *names, size_t count) {
  @autoreleasepool {
    NSMutableArray<FinderQuickLookItem *> *items = [NSMutableArray arrayWithCapacity:count];
    for (size_t i = 0; i < count; i++) {
      if (paths[i] == NULL) continue;
      NSString *path = [NSString stringWithUTF8String:paths[i]];
      if (path == nil) continue;
      FinderQuickLookItem *item = [FinderQuickLookItem new];
      item.url = [NSURL fileURLWithPath:path];
      item.displayName = names && names[i] ? [NSString stringWithUTF8String:names[i]] : path.lastPathComponent;
      [items addObject:item];
    }
    if (items.count == 0) return;

    if (dataSource == nil) dataSource = [FinderQuickLookDataSource new];
    dataSource.items = items;

    QLPreviewPanel *panel = [QLPreviewPanel sharedPreviewPanel];
    panel.dataSource = dataSource;
    [panel reloadData];
    panel.currentPreviewItemIndex = 0;
    [panel makeKeyAndOrderFront:nil];
  }
}

long finder_quicklook_current_index(void) {
  @autoreleasepool {
    QLPreviewPanel *panel = [QLPreviewPanel sharedPreviewPanel];
    if (!panel.isVisible || dataSource == nil || dataSource.items.count == 0) return -1;
    NSInteger index = panel.currentPreviewItemIndex;
    return index >= 0 && (NSUInteger)index < dataSource.items.count ? (long)index : -1;
  }
}
