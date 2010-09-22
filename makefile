name := Veency
id := vncs
flags := -lvncserver -framework IOMobileFramebuffer -framework CoreSurface -framework IOKit -framework GraphicsServices -I/apl/inc/iPhoneOS-2.0 -framework QuartzCore -weak_reference_mismatches weak -framework UIKit -framework GraphicsServices
base := ../tweaks
include ../tweaks/tweak.mk

extra:
	mkdir -p package/System/Library/CoreServices/SpringBoard.app
	cp -a Default_Veency.png FSO_Veency.png package/System/Library/CoreServices/SpringBoard.app
