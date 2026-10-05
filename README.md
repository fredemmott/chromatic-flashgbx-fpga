# Chromatic FPGA - FlashGBX

This repository contains customized firmware for the ModRetro Chromatic, adding support for the ModRetro
Chromatic.

If you want to use your Chromatic with FlashGBX, you don't need this repository; everything you need is in [my version of FlashGBX](https://github.com/fredemmott/FlashGBX/releases/latest).

If you want to flash this firmware so that FlashGBX doesn't need to reload it every time, the easiest way is to use my [chromatic-ez-firmware tool](https://github.com/fredemmott/chromatic-ez-firmware/releases).

## Developer Notes

This repository is based on https://github.com/ModRetro/oss-chromatic-console-fpga

- this adds a vendor-class USB bulk interface to the composite device
- most of the logic is in `esp32t/src/rtl/cartio/`
- there is additional logic in `top.v`, `usbuvcuart_top.v`, and `cartridge_interface.v` to support MUXing cartridge IO with the emulator
- for more general information, see [the upstream repository](https://github.com/ModRetro/oss-chromatic-console-fpga)