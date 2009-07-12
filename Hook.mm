#include <dlfcn.h>
#include <objc/runtime.h>

extern "C" void TweakInitialize() {
    if (Class star = objc_getClass("UIKeyboardLayoutStar")) {
        Method method(class_getInstanceMethod(objc_getClass("UIKeyboardLayoutRoman"), @selector(handleHardwareKeyDownFromSimulator:)));
        class_addMethod(star, @selector(handleHardwareKeyDownFromSimulator:), method_getImplementation(method), method_getTypeEncoding(method));
    }
}
