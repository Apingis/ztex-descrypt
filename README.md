### Version 30.07.16 improvements ###

Added some abstraction layer over existing API for purposes:

- Hide implementation details from the developer, such as details of operation of multi-FPGA board or link layer communication details;
- Allow host software and FPGA application to organize communication in a sequence of packets. On FPGA side, different packets might be directed into different subsystems of the application.

Example application includes:

- Processing of list of words;
- Generation of words;
- Output of results.


### 1. Overview ###

Examples/inouttraffic application for Ztex 1.15y FPGA board.

Development considerations.

- I've got such board and started application development;
- I need high-speed communication to FPGA board;
- My application would integrate with some other software written in C.

Ztex SDK does provide examples/intraffic that is far away from what can be used as a starting point for application development.

### 2. Objectives ###

- Create some basic application that can be used as a starting point for application development (examples/inouttraffic);
- Application must fully utilize USB 2.0 bandwith or hardware capabilities;
- Must support multi-FPGA board;
- Must include host software written in C;
- Host software must compile and run on Unix and Windows;
- Íost software must be able to operate several boards at same time.

### 3. Design considerations. ###

If you look at Ztex 1.15y board, you would see 4 FPGA chips and 1 USB device controller. Ztex SDK provides select_fpga() function that performs switching between FPGA's, however that's not enough.
At high-speed communication, when you switch FPGA's the best case is data arrives to wrong destination or get lost, because of USB device controller's internal buffers. In worst case the system hangs up and requires power cycle.
I found no applications for ZTEX 1.15y board that use USB device controller's High-Speed I/O interface.

Examples/inouttraffic uses following approach:

- before host writes to USB, it checks that FPGA has enough space in its input buffer; else some data get stuck in USB device controller's buffer;
- before it switches between FPGA's, it checks that FPGA completed input operation;
- FPGA does not write on will. It waits for a request from the host. On such a request, it reports the amount ready for output, and outputs exactly that many;
- Host does not switch between FPGA's until it finishes reading of amount previously reported by FPGA. After that, it's safe to switch to other FPGA.

### 4. Results ###

- HDL developer gets basic application and starts with Input and Output FIFOs;
- C developer gets basic I/O application.

### 5. Requirements ###

- Ztex SDK
- Cygwin (on Windows)
- libusb-1.0
- gcc-core
- WinUSB driver (used Zadig 2.2 to install)

### 6. Test measurements ###

- At development site, examples/intraffic from Ztex SDK performs at 30 MB/s. However that doesn't switch FPGAs and reads in 512K blocks (data generated on the fly).
- At the same site test.c displays 20 MB/s. That reads/writes 8K blocks and switches FPGAs. That can be improved by few more MB/s with increase of r/w size and increase of FPGA's internal buffer.

### 7. Host software development issues ###

Host software performs read/write operations with usb_bulk_transfer calls. That's blocking calls. So:

- if you have several boards on different USB busses, you have to address the issue to achive I/O performance.

USB speed issues.

- USB transfers in packets, with substantial packet setup overhead. You get better speed results if you use larger packets;
- USB control messages also take time and reduce I/O performance;
- Speed depends on host hardware.

### 8. TODO ###

- Add reset of erroneous device;
- Evaluate possible use of asynchronous USB transfer functions.

### 9. Related issues ###

- FPGA interconnect. Each FPGA has more than 200 I/O pins floating. I've checked if they are connected between FPGAs. Unluckily FPGAs aren't connected except for pins connected to USB device controller chip.
- Broadcast input to let same data from the host get read by all FPGA's. One FPGA could read device controller's Slave FIFO as usual while other FPGAs could listen passively. That can be done if application would require such function.
