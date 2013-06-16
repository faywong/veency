name := Veency
id := vncs
flags := -lvncserver -framework IOMobileFramebuffer -framework CoreSurface -framework IOKit -framework GraphicsServices -I/apl/inc/iPhoneOS-2.0 -framework QuartzCore -weak_reference_mismatches weak -framework UIKit -framework GraphicsServices -I/home/faywong/substrate -I/home/faywong/spirit/igor/headers -I/home/faywong/iphoneheaders/SpringBoard -I/home/faywong/iphoneheaders -I/home/faywong/iphoneheaders/_fallback -I/home/faywong/menes/substrate
flags += -fvisibility=hidden
flags += SpringBoardAccess.c
base := ../../tweaks
include ../../tweaks/tweak.mk

extra:
	mkdir -p package/System/Library/CoreServices/SpringBoard.app
	cp -a Default_Veency.png FSO_Veency.png package/System/Library/CoreServices/SpringBoard.app
