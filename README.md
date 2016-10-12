
crypt(3) Standard DES password auditing tool for Ztex 1.15y FPGA board.

Includes Verilog code, bitstream and example host software. To operate boards, you have to:
- compile-in configuration for onboard comparator (salt and hashed passwords);
- compile-in configurations for onboard candidate password generator;
- read and understand output in hexadecimal.

Compiles and runs on Linux and Windows. Supports operation of several connected boards (you have to improve host software yourself to distribute candidates among fpgas and boards). Performs at approximately 700 MH/s.

Uses Ztex USB Multi-FPGA board communication framework https://github.com/Apingis/ztex_inouttraffic

Project discontinued 10.2016 in favor of integration with John the Ripper.

"John the Ripper" password cracker
Home: http://openwall.com/john
Development version: https://github.com/magnumripper/JohnTheRipper
