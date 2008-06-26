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
	    -framework LayerKit

.PHONY: all clean test
