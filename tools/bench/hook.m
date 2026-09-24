// Linked into the builds tools/bench/run.sh measures, never into carnival.app.
// CARNIVAL_BENCH_OPEN=s opens carnival's menu s seconds after launch and
// CARNIVAL_BENCH_CLOSE=s closes it s seconds after launch: menuWillOpen, live ticks
// and redraws in a real menu window, menuDidClose. The panel's redraws are counted.
#import <AppKit/AppKit.h>
#import <objc/runtime.h>

static NSMenu *tracked;
static int draws;
static void (*drawRect)(id, SEL, NSRect);

static void countedDrawRect(id self, SEL cmd, NSRect dirty) {
    draws++;
    drawRect(self, cmd, dirty);
}

static void say(NSString *s) {
    fprintf(stderr, "bench %.1f: %s\n", NSProcessInfo.processInfo.systemUptime, s.UTF8String);
}

static void openMenu(void) {
    // The delegate's menu, popped up at a fixed point rather than under the status item:
    // the same delegate calls, the same panel view, a real menu window.
    id d = NSApp.delegate;
    Ivar iv = class_getInstanceVariable([d class], "menu");
    NSMenu *m = iv ? object_getIvar(d, iv) : nil;
    if (!m) { say(@"no menu found"); return; }
    [m popUpMenuPositioningItem:nil atLocation:NSMakePoint(300, 300) inView:nil];
}

__attribute__((constructor)) static void hook(void) {
    const char *o = getenv("CARNIVAL_BENCH_OPEN"), *c = getenv("CARNIVAL_BENCH_CLOSE");
    if (!o) return;
    double openAt = atof(o), closeAt = c ? atof(c) : 0;

    Class panel = NSClassFromString(@"carnival.Panel");
    Method m = panel ? class_getInstanceMethod(panel, @selector(drawRect:)) : NULL;
    if (m && m != class_getInstanceMethod(NSView.class, @selector(drawRect:)))
        drawRect = (void (*)(id, SEL, NSRect))method_setImplementation(m, (IMP)countedDrawRect);
    say(drawRect ? @"counting panel redraws" : @"panel class not found");

    NSNotificationCenter *nc = NSNotificationCenter.defaultCenter;
    [nc addObserverForName:NSMenuDidBeginTrackingNotification object:nil queue:nil usingBlock:^(NSNotification *n) {
        tracked = n.object;
        draws = 0;
        say(@"menu open");
    }];
    [nc addObserverForName:NSMenuDidEndTrackingNotification object:nil queue:nil usingBlock:^(NSNotification *n) {
        say([NSString stringWithFormat:@"menu closed draws=%d", draws]);
    }];
    [nc addObserverForName:NSApplicationDidFinishLaunchingNotification object:nil queue:nil usingBlock:^(NSNotification *n) {
        // Run-loop timers, not dispatch_after: tracking a menu from inside a main-queue
        // block would hold the main queue, and carnival's temperature results arrive on it.
        [NSRunLoop.mainRunLoop addTimer:[NSTimer timerWithTimeInterval:openAt repeats:NO
                                                                  block:^(NSTimer *t) { openMenu(); }]
                                forMode:NSRunLoopCommonModes];
        if (closeAt > openAt)
            [NSRunLoop.mainRunLoop addTimer:[NSTimer timerWithTimeInterval:closeAt repeats:NO
                                                                      block:^(NSTimer *t) { [tracked cancelTracking]; }]
                                    forMode:NSRunLoopCommonModes];
    }];
}
