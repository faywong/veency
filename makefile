name := Veency
id := vncs
flags := -lvncserver -framework IOMobileFramebuffer -framework CoreSurface -framework IOKit -framework GraphicsServices -I/apl/inc/iPhoneOS-2.0 -framework QuartzCore
base := ../tweaks
include ../tweaks/tweak.mk

all: VeencyHook.dylib

VeencyHook.dylib: Hook.mm makefile
	$(target)g++ -dynamiclib -g0 -O2 -Wall -Werror -o $@ $(filter %.mm,$^) -init _TweakInitialize -lobjc
	ldid -S $@

extra:
	cp -a VeencyHook.dylib VeencyHook.plist package/Library/MobileSubstrate/DynamicLibraries
	mkdir -p package/System/Library/CoreServices/SpringBoard.app
	cp -a Default_Veency.png FSO_Veency.png package/System/Library/CoreServices/SpringBoard.app
