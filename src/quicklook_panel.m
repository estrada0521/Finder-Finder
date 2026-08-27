#import <Cocoa/Cocoa.h>
#import <QuickLookUI/QuickLookUI.h>

@interface LabQuickLookDataSource : NSObject <QLPreviewPanelDataSource>
@property(nonatomic, copy) NSArray<NSURL *> *items;
@end

@implementation LabQuickLookDataSource

- (NSInteger)numberOfPreviewItemsInPreviewPanel:(QLPreviewPanel *)panel {
  return self.items.count;
}

- (id<QLPreviewItem>)previewPanel:(QLPreviewPanel *)panel previewItemAtIndex:(NSInteger)index {
  if (index < 0 || (NSUInteger)index >= self.items.count) return nil;
  return self.items[(NSUInteger)index];
}

@end

static LabQuickLookDataSource *dataSource;

void lab_quicklook_open(const char *const *paths, size_t count) {
  @autoreleasepool {
    NSMutableArray<NSURL *> *items = [NSMutableArray arrayWithCapacity:count];
    for (size_t i = 0; i < count; i++) {
      if (paths[i] == NULL) continue;
      NSString *path = [NSString stringWithUTF8String:paths[i]];
      if (path != nil) [items addObject:[NSURL fileURLWithPath:path]];
    }
    if (items.count == 0) return;

    if (dataSource == nil) dataSource = [LabQuickLookDataSource new];
    dataSource.items = items;

    QLPreviewPanel *panel = [QLPreviewPanel sharedPreviewPanel];
    panel.dataSource = dataSource;
    [panel reloadData];
    panel.currentPreviewItemIndex = 0;
    [panel makeKeyAndOrderFront:nil];
  }
}

long lab_quicklook_current_index(void) {
  @autoreleasepool {
    QLPreviewPanel *panel = [QLPreviewPanel sharedPreviewPanel];
    if (!panel.isVisible || dataSource == nil || dataSource.items.count == 0) return -1;
    NSInteger index = panel.currentPreviewItemIndex;
    return index >= 0 && (NSUInteger)index < dataSource.items.count ? (long)index : -1;
  }
}
