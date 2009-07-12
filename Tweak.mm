/* Veency - VNC Remote Access Server for iPhoneOS
 * Copyright (C) 2008  Jay Freeman (saurik)
*/

/*
 *        Redistribution and use in source and binary
 * forms, with or without modification, are permitted
 * provided that the following conditions are met:
 *
 * 1. Redistributions of source code must retain the
 *    above copyright notice, this list of conditions
 *    and the following disclaimer.
 * 2. Redistributions in binary form must reproduce the
 *    above copyright notice, this list of conditions
 *    and the following disclaimer in the documentation
 *    and/or other materials provided with the
 *    distribution.
 * 3. The name of the author may not be used to endorse
 *    or promote products derived from this software
 *    without specific prior written permission.
 *
 * THIS SOFTWARE IS PROVIDED BY THE AUTHOR ``AS IS''
 * AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING,
 * BUT NOT LIMITED TO, THE IMPLIED WARRANTIES OF
 * MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE
 * ARE DISCLAIMED. IN NO EVENT SHALL THE AUTHOR BE
 * LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL,
 * EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT
 * NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR
 * SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS
 * INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF
 * LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR
 * TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN
 * ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF
 * ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
*/

#include <substrate.h>

#include <rfb/rfb.h>
#include <rfb/keysym.h>

#include <mach/mach_port.h>

#import <QuartzCore/CAWindowServer.h>
#import <QuartzCore/CAWindowServerDisplay.h>

#import <CoreGraphics/CGGeometry.h>
#import <GraphicsServices/GraphicsServices.h>
#import <Foundation/Foundation.h>
#import <IOMobileFramebuffer/IOMobileFramebuffer.h>
#import <IOKit/IOKitLib.h>
#import <UIKit/UIKit.h>

#import <SpringBoard/SBAlertItemsController.h>
#import <SpringBoard/SBDismissOnlyAlertItem.h>
#import <SpringBoard/SBStatusBarController.h>

#define IOMobileFramebuffer "/System/Library/PrivateFrameworks/IOMobileFramebuffer.framework/IOMobileFramebuffer"

static const size_t Width = 320;
static const size_t Height = 480;
static const size_t BytesPerPixel = 4;
static const size_t BitsPerSample = 8;

static const size_t Stride = Width * BytesPerPixel;
static const size_t Size32 = Width * Height;
static const size_t Size8 = Size32 * BytesPerPixel;

static pthread_t thread_;
static rfbScreenInfoPtr screen_;
static bool running_;
static int buttons_;
static int x_, y_;

static unsigned clients_;

static Class $VNCAlertItem;
static Class $SBAlertItemsController;
static Class $SBStatusBarController;

static rfbNewClientAction action_ = RFB_CLIENT_ON_HOLD;
static NSCondition *condition_;

static rfbClientPtr client_;

static void VNCAccept() {
    action_ = RFB_CLIENT_ACCEPT;
    ++clients_;
    [[$SBStatusBarController sharedStatusBarController] addStatusBarItem:@"Veency"];
}

void VNCAlertItem$alertSheet$buttonClicked$(id self, SEL sel, id sheet, int button) {
    [condition_ lock];

    switch (button) {
        case 1:
            VNCAccept();
        break;

        case 2:
            action_ = RFB_CLIENT_REFUSE;
        break;
    }

    [condition_ signal];
    [condition_ unlock];
    [self dismiss];
}

void VNCAlertItem$configure$requirePasscodeForActions$(id self, SEL sel, BOOL configure, BOOL require) {
    UIModalView *sheet([self alertSheet]);
    [sheet setDelegate:self];
    [sheet setTitle:@"Remote Access Request"];
    [sheet setBodyText:[NSString stringWithFormat:@"Accept connection from\n%s?\n\nVeency VNC Server\nby Jay Freeman (saurik)\nsaurik@saurik.com\nhttp://www.saurik.com/", client_->host]];
    [sheet addButtonWithTitle:@"Accept"];
    [sheet addButtonWithTitle:@"Reject"];
}

void VNCAlertItem$performUnlockAction(id self, SEL sel) {
    [[$SBAlertItemsController sharedInstance] activateAlertItem:self];
}

@interface VNCBridge : NSObject {
}

+ (void) askForConnection;
+ (void) removeStatusBarItem;

@end

@implementation VNCBridge

+ (void) askForConnection {
    if (false) {
        [condition_ lock];
        VNCAccept();
        [condition_ signal];
        [condition_ unlock];
    } else {
        id item = [[[$VNCAlertItem alloc] init] autorelease];
        [[$SBAlertItemsController sharedInstance] activateAlertItem:item];
    }
}

+ (void) removeStatusBarItem {
    [[$SBStatusBarController sharedStatusBarController] removeStatusBarItem:@"Veency"];
}

@end

static mach_port_t (*GSTakePurpleSystemEventPort)(void);
static bool PurpleAllocated;
static bool Two_;

static void FixRecord(GSEventRecord *record) {
    if (Two_)
        memmove(&record->windowContextId, &record->windowContextId + 1, sizeof(*record) - (reinterpret_cast<uint8_t *>(&record->windowContextId + 1) - reinterpret_cast<uint8_t *>(record)) + record->size);
}

static void VNCPointer(int buttons, int x, int y, rfbClientPtr client) {
    x_ = x; y_ = y;
    int diff = buttons_ ^ buttons;
    bool twas((buttons_ & 0x1) != 0);
    bool tis((buttons & 0x1) != 0);
    buttons_ = buttons;

    rfbDefaultPtrAddEvent(buttons, x, y, client);

    mach_port_t purple(0);

    if ((diff & 0x10) != 0) {
        struct GSEventRecord record;

        memset(&record, 0, sizeof(record));

        record.type = (buttons & 0x4) != 0 ?
            GSEventTypeHeadsetButtonDown :
            GSEventTypeHeadsetButtonUp;

        record.timestamp = GSCurrentEventTimestamp();

        FixRecord(&record);
        GSSendSystemEvent(&record);
    }

    if ((diff & 0x04) != 0) {
        struct GSEventRecord record;

        memset(&record, 0, sizeof(record));

        record.type = (buttons & 0x4) != 0 ?
            GSEventTypeMenuButtonDown :
            GSEventTypeMenuButtonUp;

        record.timestamp = GSCurrentEventTimestamp();

        FixRecord(&record);
        GSSendSystemEvent(&record);
    }

    if ((diff & 0x02) != 0) {
        struct GSEventRecord record;

        memset(&record, 0, sizeof(record));

        record.type = (buttons & 0x2) != 0 ?
            GSEventTypeLockButtonDown :
            GSEventTypeLockButtonUp;

        record.timestamp = GSCurrentEventTimestamp();

        FixRecord(&record);
        GSSendSystemEvent(&record);
    }

    if (twas != tis || tis) {
        struct {
            struct GSEventRecord record;
            struct {
                struct GSEventRecordInfo info;
                struct GSPathInfo path;
            } data;
        } event;

        memset(&event, 0, sizeof(event));

        event.record.type = GSEventTypeMouse;
        event.record.locationInWindow.x = x;
        event.record.locationInWindow.y = y;
        event.record.timestamp = GSCurrentEventTimestamp();
        event.record.size = sizeof(event.data);

        event.data.info.handInfo.type = twas == tis ?
            GSMouseEventTypeDragged :
        tis ?
            GSMouseEventTypeDown :
            GSMouseEventTypeUp;

        event.data.info.handInfo.x34 = 0x1;
        event.data.info.handInfo.x38 = tis ? 0x1 : 0x0;

        event.data.info.pathPositions = 1;

        event.data.path.x00 = 0x01;
        event.data.path.x01 = 0x02;
        event.data.path.x02 = tis ? 0x03 : 0x00;
        event.data.path.position = event.record.locationInWindow;

        mach_port_t port(0);

        if (CAWindowServer *server = [CAWindowServer serverIfRunning]) {
            NSArray *displays([server displays]);
            if (displays != nil && [displays count] != 0)
                if (CAWindowServerDisplay *display = [displays objectAtIndex:0])
                    port = [display clientPortAtPosition:event.record.locationInWindow];
        }

        if (port == 0) {
            if (purple == 0)
                purple = (*GSTakePurpleSystemEventPort)();
            port = purple;
        }

        FixRecord(&event.record);
        GSSendEvent(&event.record, port);
    }

    if (purple != 0 && PurpleAllocated)
        mach_port_deallocate(mach_task_self(), purple);
}

static void VNCKeyboard(rfbBool down, rfbKeySym key, rfbClientPtr client) {
    if (!down)
        return;

    switch (key) {
        case XK_Return: key = '\r'; break;
        case XK_BackSpace: key = 0x7f; break;
    }

    if (key > 0xfff)
        return;

    GSEventRef event(_GSCreateSyntheticKeyEvent(key, YES, YES));
    GSEventRecord *record(_GSEventGetGSEventRecord(event));
    record->type = GSEventTypeKeyDown;

    mach_port_t port(0);

    if (CAWindowServer *server = [CAWindowServer serverIfRunning]) {
        NSArray *displays([server displays]);
        if (displays != nil && [displays count] != 0)
            if (CAWindowServerDisplay *display = [displays objectAtIndex:0])
                port = [display clientPortAtPosition:CGPointMake(x_, y_)];
    }

    mach_port_t purple(0);

    if (port == 0) {
        if (purple == 0)
            purple = (*GSTakePurpleSystemEventPort)();
        port = purple;
    }

    if (port != 0)
        GSSendEvent(record, port);

    if (purple != 0 && PurpleAllocated)
        mach_port_deallocate(mach_task_self(), purple);

    CFRelease(event);
}

static void VNCDisconnect(rfbClientPtr client) {
    if (--clients_ == 0)
        [VNCBridge performSelectorOnMainThread:@selector(removeStatusBarItem) withObject:nil waitUntilDone:NO];
}

static rfbNewClientAction VNCClient(rfbClientPtr client) {
    [condition_ lock];
    client_ = client;
    [VNCBridge performSelectorOnMainThread:@selector(askForConnection) withObject:nil waitUntilDone:NO];
    while (action_ == RFB_CLIENT_ON_HOLD)
        [condition_ wait];
    rfbNewClientAction action(action_);
    action_ = RFB_CLIENT_ON_HOLD;
    [condition_ unlock];
    if (action == RFB_CLIENT_ACCEPT)
        client->clientGoneHook = &VNCDisconnect;
    return action;
}

static rfbPixel black_[320][480];

static void *VNCServer(IOMobileFramebufferRef fb) {
    CGRect rect(CGRectMake(0, 0, Width, Height));

    /*CoreSurfaceBufferRef surface(NULL);
    kern_return_t value(IOMobileFramebufferGetLayerDefaultSurface(fb, 0, &surface));
    if (value != 0)
        return NULL;*/

    condition_ = [[NSCondition alloc] init];

    int argc(1);
    char *arg0(strdup("VNCServer"));
    char *argv[] = {arg0, NULL};

    screen_ = rfbGetScreen(&argc, argv, Width, Height, BitsPerSample, 3, BytesPerPixel);
    screen_->desktopName = "iPhone";
    screen_->alwaysShared = TRUE;
    screen_->handleEventsEagerly = TRUE;
    screen_->deferUpdateTime = 5;

    screen_->serverFormat.redShift = BitsPerSample * 2;
    screen_->serverFormat.greenShift = BitsPerSample * 1;
    screen_->serverFormat.blueShift = BitsPerSample * 0;

    /*io_service_t service(IOServiceGetMatchingService(kIOMasterPortDefault, IOServiceMatching("IOCoreSurfaceRoot")));
    CFMutableDictionaryRef properties(NULL);
    IORegistryEntryCreateCFProperties(service, &properties, kCFAllocatorDefault, kNilOptions);

    CoreSurfaceBufferLock(surface, kCoreSurfaceLockTypeGimmeVRAM);
    screen_->frameBuffer = reinterpret_cast<char *>(CoreSurfaceBufferGetBaseAddress(surface));
    CoreSurfaceBufferUnlock(surface);
    CFRelease(surface);*/

    screen_->frameBuffer = reinterpret_cast<char *>(black_);

    screen_->kbdAddEvent = &VNCKeyboard;
    screen_->ptrAddEvent = &VNCPointer;

    screen_->newClientHook = &VNCClient;

    /*char data[0], mask[0];
    rfbCursorPtr cursor = rfbMakeXCursor(0, 0, data, mask);
    rfbSetCursor(screen_, cursor);*/

    rfbInitServer(screen_);
    running_ = true;

    rfbRunEventLoop(screen_, -1, true);
    NSLog(@"rfbRunEventLoop().");
    return NULL;

    running_ = false;
    rfbScreenCleanup(screen_);

    free(arg0);
    return NULL;
}

MSHook(kern_return_t, IOMobileFramebufferSwapSetLayer,
    IOMobileFramebufferRef fb,
    int layer,
    CoreSurfaceBufferRef buffer,
    CGRect bounds,
    CGRect frame,
    int flags
) {
    /*if (
        bounds.origin.x != 0 || bounds.origin.y != 0 || bounds.size.width != 320 || bounds.size.height != 480 ||
        frame.origin.x != 0 || frame.origin.y != 0 || frame.size.width != 320 || frame.size.height != 480
    ) NSLog(@"VNC:%f,%f:%f,%f:%f,%f:%f,%f",
        bounds.origin.x, bounds.origin.y, bounds.size.width, bounds.size.height,
        frame.origin.x, frame.origin.y, frame.size.width, frame.size.height
    );*/

    if (running_) {
        if (buffer == NULL)
            screen_->frameBuffer = reinterpret_cast<char *>(black_);
        else {
            CoreSurfaceBufferLock(buffer, 2);
            rfbPixel (*data)[480] = reinterpret_cast<rfbPixel (*)[480]>(CoreSurfaceBufferGetBaseAddress(buffer));
            screen_->frameBuffer = const_cast<char *>(reinterpret_cast<volatile char *>(data));
            CoreSurfaceBufferUnlock(buffer);
        }
    }

    kern_return_t value(_IOMobileFramebufferSwapSetLayer(fb, layer, buffer, bounds, frame, flags));

    if (thread_ == NULL)
        pthread_create(&thread_, NULL, &VNCServer, fb);
    else if (running_)
        rfbMarkRectAsModified(screen_, 0, 0, Width, Height);

    return value;
}

extern "C" void TweakInitialize() {
    GSTakePurpleSystemEventPort = reinterpret_cast<mach_port_t (*)()>(dlsym(RTLD_DEFAULT, "GSGetPurpleSystemEventPort"));
    if (GSTakePurpleSystemEventPort == NULL) {
        GSTakePurpleSystemEventPort = reinterpret_cast<mach_port_t (*)()>(dlsym(RTLD_DEFAULT, "GSCopyPurpleSystemEventPort"));
        PurpleAllocated = true;
    }

    Two_ = dlsym(RTLD_DEFAULT, "GSEventGetWindowContextId") == NULL;

    MSHookFunction(&IOMobileFramebufferSwapSetLayer, &$IOMobileFramebufferSwapSetLayer, &_IOMobileFramebufferSwapSetLayer);

    $SBAlertItemsController = objc_getClass("SBAlertItemsController");
    $SBStatusBarController = objc_getClass("SBStatusBarController");

    $VNCAlertItem = objc_allocateClassPair(objc_getClass("SBAlertItem"), "VNCAlertItem", 0);
    class_addMethod($VNCAlertItem, @selector(alertSheet:buttonClicked:), (IMP) &VNCAlertItem$alertSheet$buttonClicked$, "v@:@i");
    class_addMethod($VNCAlertItem, @selector(configure:requirePasscodeForActions:), (IMP) &VNCAlertItem$configure$requirePasscodeForActions$, "v@:cc");
    class_addMethod($VNCAlertItem, @selector(performUnlockAction), (IMP) VNCAlertItem$performUnlockAction, "v@:");
    objc_registerClassPair($VNCAlertItem);
}
