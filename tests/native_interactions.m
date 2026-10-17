// From the repo root:
// clang -fobjc-arc tests/native_interactions.m -framework Cocoa -framework CoreServices -framework QuickLookThumbnailing -framework QuickLookUI -Wl,-undefined,dynamic_lookup -o /tmp/finder-native-interactions
// /tmp/finder-native-interactions
// Offscreen AppKit tests; no Rust actions or real database access.
#import "../src/native_shell.m"

@interface InteractionWindow : NSWindow
@property(nonatomic) NSEventType nextType;
@end
@implementation InteractionWindow
- (NSEvent *)nextEventMatchingMask:(NSEventMask)mask {
  return [NSEvent mouseEventWithType:self.nextType location:NSZeroPoint modifierFlags:0 timestamp:0 windowNumber:0 context:nil eventNumber:0 clickCount:1 pressure:1];
}
@end

@interface InteractionOwner : NSObject <FinderPayloadDragOwner, NSTableViewDataSource>
@property(nonatomic) NSArray *records;
@property(nonatomic) FinderRecordTable *table;
@property(nonatomic) NSUInteger opens;
@property(nonatomic) NSUInteger previews;
@property(nonatomic) NSUInteger drags;
@property(nonatomic, weak) NSView *dragSource;
@end
@implementation InteractionOwner
- (NSInteger)numberOfRowsInTableView:(NSTableView *)table { return self.records.count; }
- (void)openSelected { self.opens++; }
- (void)quickLookSelected { self.previews++; }
- (void)beginPayloadDragFromView:(NSView *)view event:(NSEvent *)event { self.drags++; self.dragSource = view; }
- (NSMenu *)contextMenuForRow:(NSInteger)row { return [[NSMenu alloc] initWithTitle:@"Record actions"]; }
@end

@interface MainHitTable : FinderNativeTable
@property(nonatomic) NSInteger hitRow;
@end
@implementation MainHitTable
- (NSInteger)rowAtPoint:(NSPoint)point { return self.hitRow; }
@end
@interface RelatedHitTable : FinderRelatedTable
@property(nonatomic) NSInteger hitRow;
@end
@implementation RelatedHitTable
- (NSInteger)rowAtPoint:(NSPoint)point { return self.hitRow; }
@end
@interface HitGrid : FinderGridView
@property(nonatomic) NSInteger hitRow;
@end
@implementation HitGrid
- (NSIndexPath *)indexPathForItemAtPoint:(NSPoint)point { return self.hitRow < 0 ? nil : [NSIndexPath indexPathForItem:self.hitRow inSection:0]; }
@end

static void Require(BOOL condition, NSString *label) {
  if (!condition) { NSLog(@"FAIL: %@", label); exit(1); }
}
static NSEvent *Click(NSEventModifierFlags flags, NSInteger count) {
  return [NSEvent mouseEventWithType:NSEventTypeLeftMouseDown location:NSZeroPoint modifierFlags:flags timestamp:0 windowNumber:0 context:nil eventNumber:0 clickCount:count pressure:1];
}
static void Select(NSView *view, NSInteger row, NSEventModifierFlags flags, NSInteger count) {
  [(id)view setHitRow:row]; [view mouseDown:Click(flags, count)];
}
static void Range(FinderRecordTable *table, NSUInteger first, NSUInteger count) {
  Require([table.selectedRowIndexes isEqualToIndexSet:[NSIndexSet indexSetWithIndexesInRange:NSMakeRange(first,count)]], @"contiguous selection");
}
static void Exercise(NSInteger presentation) {
  InteractionOwner *owner = [InteractionOwner new];
  NSMutableArray *records = [NSMutableArray array];
  for (int i=0; i<20; i++) [records addObject:@{@"id": [NSString stringWithFormat:@"%06d", i], @"title": @"test"}];
  owner.records = records;
  FinderRecordTable *table = (presentation == 1 || presentation == 3) ? [RelatedHitTable new] : [MainHitTable new];
  table.owner=owner; table.dataSource=owner; table.allowsMultipleSelection=YES; table.allowsEmptySelection=YES;
  [table addTableColumn:[[NSTableColumn alloc] initWithIdentifier:@"test"]]; [table reloadData]; owner.table=table;
  NSView *view=table;
  FinderGridController *grid=nil;
  if (presentation >= 2) {
    grid=[[FinderGridController alloc] initWithOwner:owner table:table];
    HitGrid *collection=[[HitGrid alloc] initWithFrame:NSMakeRect(0,0,676,496)];
    collection.gridOwner=grid; collection.dataSource=grid; collection.delegate=grid;
    collection.selectable=YES; collection.allowsMultipleSelection=YES;
    NSCollectionViewFlowLayout *layout=[NSCollectionViewFlowLayout new]; layout.itemSize=NSMakeSize(120,140); collection.collectionViewLayout=layout;
    [collection registerClass:FinderGridItem.class forItemWithIdentifier:@"grid-record"];
    grid.view=collection; [grid reload]; view=collection;
  }
  InteractionWindow *window=[[InteractionWindow alloc] initWithContentRect:NSMakeRect(0,0,676,496) styleMask:NSWindowStyleMaskBorderless backing:NSBackingStoreBuffered defer:NO];
  window.releasedWhenClosed=NO; window.nextType=NSEventTypeLeftMouseUp; window.contentView=view;
  Select(view,2,0,1); Range(table,2,1); Require(owner.opens==0 && owner.previews==0,@"first click only selects");
  Select(view,8,NSEventModifierFlagShift,1); Range(table,2,7);
  Select(view,5,NSEventModifierFlagShift,1); Range(table,2,4);
  Select(view,12,NSEventModifierFlagCommand,1); Require(table.selectedRowIndexes.count==5,@"command adds item");
  Select(view,8,NSEventModifierFlagCommand|NSEventModifierFlagShift,1);
  Require(table.selectedRowIndexes.count==9 && [table.selectedRowIndexes containsIndex:2] && [table.selectedRowIndexes containsIndex:12],@"command shift adds reverse range");
  Select(view,8,NSEventModifierFlagCommand,1); Require(![table.selectedRowIndexes containsIndex:8],@"command toggles item off");
  Require(owner.opens==0 && owner.previews==0,@"selection gestures do not open files or previews");
  [(id)view setHitRow:1]; Require([[view menuForEvent:Click(0,1)].title isEqual:@"Record actions"],@"same context menu"); Range(table,1,1);
  Select(view,3,NSEventModifierFlagOption,1); Range(table,3,1); Require(owner.opens==1,@"option click opens payload");
  Select(view,3,0,2); Require(owner.opens==1 && owner.previews==1,@"double click previews instead of opening app");
  Select(view,4,0,1);
  NSEvent *space=[NSEvent keyEventWithType:NSEventTypeKeyDown location:NSZeroPoint modifierFlags:0 timestamp:0 windowNumber:0 context:nil characters:@" " charactersIgnoringModifiers:@" " isARepeat:NO keyCode:49];
  [view keyDown:space]; Require(owner.previews==2,@"space previews");
  window.nextType=NSEventTypeLeftMouseDragged;
  Select(view,4,0,1); Require(owner.drags==1 && owner.dragSource==view && owner.previews==2,@"drag uses visible source without preview");
  if (grid) Require(grid.view.selectionIndexPaths.count==table.selectedRowIndexes.count,@"grid selection matches action model");
  NSInteger anchor=table.selectionAnchor; [table reloadPresentation]; Require(table.selectionAnchor==anchor,@"layout reload preserves range anchor");
  [table reloadData]; Require(table.selectionAnchor==-1,@"catalog reload invalidates selection anchor");
  [window close];
}
int main(void) {
  @autoreleasepool {
    [NSApplication sharedApplication];
    Exercise(0); Exercise(1); Exercise(2); Exercise(3);
    puts("PASS: main list, links list and grid share range/toggle selection, context menu, option-open, double-click preview, Space and drag behavior");
  }
  return 0;
}
