#import <LayerKit/LKPurpleServer.h>
#import <CoreFoundation/CFData.h>
#import <CoreGraphics/CGBitmapContext.h>

#include <stdint.h>
#include <stdlib.h>
#include <rfb/rfb.h>

static const size_t Width = 320;
static const size_t Height = 480;
static const size_t BytesPerPixel = 4;
static const size_t BitsPerComponent = 8;

static const size_t Stride = Width * BytesPerPixel;
static const size_t Size32 = Width * Height;
static const size_t Size8 = Size32 * BytesPerPixel;

CGContextRef CreateContext() {
    uint8_t *buffer = (uint8_t *) malloc(Size8);
    if (buffer == NULL)
        return NULL;

    CGColorSpaceRef space = CGColorSpaceCreateWithName(kCGColorSpaceGenericRGB);

    CGContextRef context = CGBitmapContextCreate(buffer, Width, Height, BitsPerComponent, Stride, space, kCGImageAlphaPremultipliedLast | kCGBitmapByteOrder32Big);
    if (context == NULL)
        free(buffer);

    CGColorSpaceRelease(space);
    return context;
}

int main(int argc, char *argv[]) {
    CGContextRef context0 = CreateContext();
    CGContextRef context1 = CreateContext();

    CGRect rect = CGRectMake(0, 0, Width, Height);

    rfbScreenInfoPtr screen = rfbGetScreen(&argc, argv, Width, Height, BitsPerComponent, 3, BytesPerPixel);

    screen->desktopName = "iPhone";
    screen->alwaysShared = TRUE;

    rfbInitServer(screen);

    for (;;) {
        CGContextRef context = context1;
        context1 = context0;
        context0 = context;

        uint8_t *buffer0 = (uint8_t *) CGBitmapContextGetData(context0);
        uint8_t *buffer1 = (uint8_t *) CGBitmapContextGetData(context1);
        screen->frameBuffer = (char *) buffer0;

        CGImageRef image = LKPurpleServerGetScreenImage(NULL);
        CGContextDrawImage(context0, rect, image);
        CFRelease(image);

        if (memcmp(buffer0, buffer1, Size8) != 0)
            rfbMarkRectAsModified(screen, 0, 0, Width, Height);
        rfbProcessEvents(screen, 100000);
    }


    rfbScreenCleanup(screen);

    return 0;
}
