/* Veency - VNC Remote Access Server for iPhoneOS
 * Copyright (C) 2008-2009  Jay Freeman (saurik)
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

#define _trace() \
    fprintf(stderr, "_trace()@%s:%u[%s]\n", __FILE__, __LINE__, __FUNCTION__)

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

static const size_t Width = 320;
static const size_t Height = 480;
static const size_t BytesPerPixel = 4;
static const size_t BitsPerSample = 8;

static const size_t Stride = Width * BytesPerPixel;
static const size_t Size32 = Width * Height;
static const size_t Size8 = Size32 * BytesPerPixel;

static NSMutableSet *handlers_;
static rfbScreenInfoPtr screen_;
static bool running_;
static int buttons_;
static int x_, y_;

static unsigned clients_;

MSClassHook(SBAlertItemsController)
MSClassHook(SBStatusBarController)

@class VNCAlertItem;
static Class $VNCAlertItem;

static rfbNewClientAction action_ = RFB_CLIENT_ON_HOLD;
static NSCondition *condition_;
static NSLock *lock_;

static rfbClientPtr client_;

@interface VNCBridge : NSObject {
}

+ (void) askForConnection;
+ (void) removeStatusBarItem;
+ (void) registerClient;

@end

@implementation VNCBridge

+ (void) askForConnection {
    [[$SBAlertItemsController sharedInstance] activateAlertItem:[[[$VNCAlertItem alloc] init] autorelease]];
}

+ (void) removeStatusBarItem {
    [[$SBStatusBarController sharedStatusBarController] removeStatusBarItem:@"Veency"];
}

+ (void) registerClient {
    ++clients_;
    [[$SBStatusBarController sharedStatusBarController] addStatusBarItem:@"Veency"];
}

@end

MSInstanceMessage2(void, VNCAlertItem, alertSheet,buttonClicked, id, sheet, int, button) {
    [condition_ lock];

    switch (button) {
        case 1:
            action_ = RFB_CLIENT_ACCEPT;
            [VNCBridge registerClient];
        break;

        case 2:
            action_ = RFB_CLIENT_REFUSE;
        break;
    }

    [condition_ signal];
    [condition_ unlock];
    [self dismiss];
}

MSInstanceMessage2(void, VNCAlertItem, configure,requirePasscodeForActions, BOOL, configure, BOOL, require) {
    UIModalView *sheet([self alertSheet]);
    [sheet setDelegate:self];
    [sheet setTitle:@"Remote Access Request"];
    [sheet setBodyText:[NSString stringWithFormat:@"Accept connection from\n%s?\n\nVeency VNC Server\nby Jay Freeman (saurik)\nsaurik@saurik.com\nhttp://www.saurik.com/\n\nSet a VNC password in Settings!", client_->host]];
    [sheet addButtonWithTitle:@"Accept"];
    [sheet addButtonWithTitle:@"Reject"];
}

MSInstanceMessage0(void, VNCAlertItem, performUnlockAction) {
    [[$SBAlertItemsController sharedInstance] activateAlertItem:self];
}

static mach_port_t (*GSTakePurpleSystemEventPort)(void);
static bool PurpleAllocated;
static bool Two_;

static void FixRecord(GSEventRecord *record) {
    if (Two_)
        memmove(&record->windowContextId, &record->windowContextId + 1, sizeof(*record) - (reinterpret_cast<uint8_t *>(&record->windowContextId + 1) - reinterpret_cast<uint8_t *>(record)) + record->size);
}

static void VNCSettings() {
    NSDictionary *settings([NSDictionary dictionaryWithContentsOfFile:[NSString stringWithFormat:@"%@/Library/Preferences/com.saurik.Veency.plist", NSHomeDirectory()]]);

    @synchronized (lock_) {
        for (NSValue *handler in handlers_)
            rfbUnregisterSecurityHandler(reinterpret_cast<rfbSecurityHandler *>([handler pointerValue]));
        [handlers_ removeAllObjects];
    }

    @synchronized (condition_) {
        if (screen_ == NULL)
            return;

        [reinterpret_cast<NSString *>(screen_->authPasswdData) release];
        screen_->authPasswdData = NULL;

        if (settings != nil)
            if (NSString *password = [settings objectForKey:@"Password"])
                if ([password length] != 0)
                    screen_->authPasswdData = [password retain];
    }
}

static void VNCNotifySettings(
    CFNotificationCenterRef center,
    void *observer,
    CFStringRef name,
    const void *object,
    CFDictionaryRef info
) {
    VNCSettings();
}

static rfbBool VNCCheck(rfbClientPtr client, const char *data, int size) {
    @synchronized (condition_) {
        if (NSString *password = reinterpret_cast<NSString *>(screen_->authPasswdData)) {
            rfbEncryptBytes(client->authChallenge, const_cast<char *>([password UTF8String]));
            return memcmp(client->authChallenge, data, size) == 0;
        } return TRUE;
    }
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
    @synchronized (condition_) {
        if (screen_->authPasswdData != NULL) {
            [VNCBridge performSelectorOnMainThread:@selector(registerClient) withObject:nil waitUntilDone:YES];
            client->clientGoneHook = &VNCDisconnect;
            return RFB_CLIENT_ACCEPT;
        }
    }

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

static void VNCSetup() {
    @synchronized (condition_) {
        int argc(1);
        char *arg0(strdup("VNCServer"));
        char *argv[] = {arg0, NULL};
        screen_ = rfbGetScreen(&argc, argv, Width, Height, BitsPerSample, 3, BytesPerPixel);
        free(arg0);

        VNCSettings();
    }

    screen_->desktopName = strdup([[[NSProcessInfo processInfo] hostName] UTF8String]);

    screen_->alwaysShared = TRUE;
    screen_->handleEventsEagerly = TRUE;
    screen_->deferUpdateTime = 5;

    screen_->serverFormat.redShift = BitsPerSample * 2;
    screen_->serverFormat.greenShift = BitsPerSample * 1;
    screen_->serverFormat.blueShift = BitsPerSample * 0;

    screen_->frameBuffer = reinterpret_cast<char *>(black_);

    screen_->kbdAddEvent = &VNCKeyboard;
    screen_->ptrAddEvent = &VNCPointer;

    screen_->newClientHook = &VNCClient;
    screen_->passwordCheck = &VNCCheck;

    /*char data[0], mask[0];
    rfbCursorPtr cursor = rfbMakeXCursor(0, 0, data, mask);
    rfbSetCursor(screen_, cursor);*/
}

static void VNCEnabled() {
    [lock_ lock];

    bool enabled(true);
    if (NSDictionary *settings = [NSDictionary dictionaryWithContentsOfFile:[NSString stringWithFormat:@"%@/Library/Preferences/com.saurik.Veency.plist", NSHomeDirectory()]])
        if (NSNumber *number = [settings objectForKey:@"Enabled"])
            enabled = [number boolValue];
    if (enabled != running_)
        if (enabled) {
            running_ = true;
            screen_->socketState = RFB_SOCKET_INIT;
            rfbInitServer(screen_);
            rfbRunEventLoop(screen_, -1, true);
        } else {
            rfbShutdownServer(screen_, true);
            running_ = false;
        }

    [lock_ unlock];
}

static void VNCNotifyEnabled(
    CFNotificationCenterRef center,
    void *observer,
    CFStringRef name,
    const void *object,
    CFDictionaryRef info
) {
    VNCEnabled();
}

MSHook(kern_return_t, IOMobileFramebufferSwapSetLayer,
    IOMobileFramebufferRef fb,
    int layer,
    CoreSurfaceBufferRef buffer,
    CGRect bounds,
    CGRect frame,
    int flags
) {
    if (running_) {
        if (buffer == NULL)
            screen_->frameBuffer = reinterpret_cast<char *>(black_);
        else {
            CoreSurfaceBufferLock(buffer, 2);
            rfbPixel (*data)[480] = reinterpret_cast<rfbPixel (*)[480]>(CoreSurfaceBufferGetBaseAddress(buffer));
            screen_->frameBuffer = const_cast<char *>(reinterpret_cast<volatile char *>(data));
            CoreSurfaceBufferUnlock(buffer);
        }

        rfbMarkRectAsModified(screen_, 0, 0, Width, Height);
    }

    return _IOMobileFramebufferSwapSetLayer(fb, layer, buffer, bounds, frame, flags);
}

MSHook(void, rfbRegisterSecurityHandler, rfbSecurityHandler *handler) {
    NSAutoreleasePool *pool([[NSAutoreleasePool alloc] init]);

    @synchronized (lock_) {
        [handlers_ addObject:[NSValue valueWithPointer:handler]];
        _rfbRegisterSecurityHandler(handler);
    }

    [pool release];
}

MSInitialize {
    NSAutoreleasePool *pool([[NSAutoreleasePool alloc] init]);

    MSHookSymbol(GSTakePurpleSystemEventPort, "GSGetPurpleSystemEventPort");
    if (GSTakePurpleSystemEventPort == NULL) {
        MSHookSymbol(GSTakePurpleSystemEventPort, "GSCopyPurpleSystemEventPort");
        PurpleAllocated = true;
    }

    Two_ = dlsym(RTLD_DEFAULT, "GSEventGetWindowContextId") == NULL;

    MSHookFunction(&IOMobileFramebufferSwapSetLayer, MSHake(IOMobileFramebufferSwapSetLayer));
    MSHookFunction(&rfbRegisterSecurityHandler, MSHake(rfbRegisterSecurityHandler));

    $VNCAlertItem = objc_allocateClassPair(objc_getClass("SBAlertItem"), "VNCAlertItem", 0);
    MSAddMessage2(VNCAlertItem, "v@:@i", alertSheet,buttonClicked);
    MSAddMessage2(VNCAlertItem, "v@:cc", configure,requirePasscodeForActions);
    MSAddMessage0(VNCAlertItem, "v@:", performUnlockAction);
    objc_registerClassPair($VNCAlertItem);

    CFNotificationCenterAddObserver(
        CFNotificationCenterGetDarwinNotifyCenter(),
        NULL, &VNCNotifyEnabled, CFSTR("com.saurik.Veency-Enabled"), NULL, 0
    );

    CFNotificationCenterAddObserver(
        CFNotificationCenterGetDarwinNotifyCenter(),
        NULL, &VNCNotifySettings, CFSTR("com.saurik.Veency-Settings"), NULL, 0
    );

    condition_ = [[NSCondition alloc] init];
    lock_ = [[NSLock alloc] init];
    handlers_ = [[NSMutableSet alloc] init];

    [pool release];

    VNCSetup();
    VNCEnabled();
}
