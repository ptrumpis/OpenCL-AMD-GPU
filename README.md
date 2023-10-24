# OpenCL-AMD-GPU
A possible fix for OpenCL detection problems on AMD Radeon GPU's.

![amdocl](https://user-images.githubusercontent.com/116500225/228428316-f24ba410-00fd-49ee-a173-f2ad7e27a433.PNG)

It will scan your system for *OpenCL Installable Client Driver (ICD)* files by AMD and register them on Windows.
- amdocl.dll
- amdocl12cl.dll
- amdocl12cl64.dll
- amdocl32.dll
- amdocl64.dll

## Usage
1. Make sure to have the latest [AMD drivers](https://www.amd.com/en/support) installed
2. Download and execute `amdocl.bat`
3. Run the file as **Administrator** (Right click file and select `Run as Administrator`)

## Notes
Inspired by StackOverflow https://stackoverflow.com/a/28407851

---

© 2023 [Patrick Trumpis](https://github.com/ptrumpis)
