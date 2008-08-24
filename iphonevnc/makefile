all: iPhoneVNC

clean:
	rm -f iPhoneVNC

test: all
	./iPhoneVNC

iPhoneVNC: iPhoneVNC.mm makefile
	g++ -g0 -O3 -o $@ $< -I. \
            -lvncserver -lz \
	    -framework CoreFoundation \
	    -framework CoreGraphics \
	    -framework UIKit \
            -lobjc \
            -framework Foundation
	ldid -S iPhoneVNC

.PHONY: all clean test
