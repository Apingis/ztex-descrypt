#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/time.h>
#include <signal.h>
#include <errno.h>
#include <unistd.h>
#include <libusb-1.0/libusb.h>

#include "ztex.h"

// ***************************************************************
//
// Task: upload firmware onto a board with no default firmware
//
// Usage: ./fw_upload [filename]
//
// If filename is not specified, prints a list of devices with no firmware
//
// ***************************************************************

libusb_device_handle *device_open(libusb_device *usb_dev)
{
	struct libusb_device_handle *handle;

	int result = libusb_open(usb_dev, &handle);
	if (result < 0) {
		fprintf(stderr, "libusb_open returns %d (%s)\n",
				result, libusb_strerror(result));
		return NULL;
	}
	return handle;
}	

void cypress_scan(char *filename)
{
	libusb_device **usb_devs;
	int result;
	int count = 0;
	ssize_t cnt;
	
	cnt = libusb_get_device_list(NULL, &usb_devs);
	if (cnt < 0) {
		fprintf(stderr, "libusb_get_device_list: %s\n",
				libusb_strerror((int)cnt));
		return;
	}

	int i;
	for (i = 0; usb_devs[i]; i++) {
		libusb_device *usb_dev = usb_devs[i];
		
		struct libusb_device_descriptor desc;
		result = libusb_get_device_descriptor(usb_dev, &desc);
		if (result < 0) {
			fprintf(stderr, "libusb_get_device_descriptor: %s\n",
					libusb_strerror(result));
			continue;
		}
	
		if (desc.idVendor != 0x04b4 || desc.idProduct != 0x8613)
			continue;
			
		int busnum = libusb_get_bus_number(usb_dev);
		int devnum = libusb_get_device_address(usb_dev);
		printf("Found Cypress device: busnum %d, devnum %d\n", busnum, devnum);
		
		libusb_device_handle *handle = device_open(usb_dev);
		if (!handle)
			continue;
			
		if (!filename)
			continue;
			
		struct ztex_device *dev = malloc(sizeof(struct ztex_device));
		dev->handle = handle;
		//sprintf("%d %d", dev->snString, busnum, devnum);
		
		ZTEX_DEBUG = 1;
		ztex_firmware_upload(dev, filename);
	}
}

int main(int argc, char **argv)
{
	int result = libusb_init(NULL);
	if (result < 0) {
		fprintf(stderr, "libusb_init(): %s\n", libusb_strerror(result));
		exit(EXIT_FAILURE);
	}

	//libusb_device *usb_dev;
	//struct libusb_device_handle *handle;
	
	if (argc == 2)
		cypress_scan(argv[1]);
	else
		cypress_scan(NULL);

	libusb_exit(NULL);
}

