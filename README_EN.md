# A-FOT

## Overview

Automatic Feedback-Directed Optimization Tool (A-FOT) is a tool designed to enhance the usability of the automatic feedback-directed optimization (AutoFDO) feature of openEuler GCC.
This tool enables the full AutoFDO workflow (including sampling, analysis, and optimization) with minimal configuration, streamlining the use of the AutoFDO feature and boosting the performance.

## Environment Dependencies

1. Compiler: GCC for openEuler 12.3.1
2. CPU architecture: x86_64 or AArch64

## Installation

1. `git clone https://gitee.com/openeuler/A-FOT.git`
2. `yum install -y A-FOT` (only for openEuler 22.03 LTS)

## Instructions

1. Configure arguments. 
`a-fot.ini`
2. Start optimization. 
`a-fot --config_file a-fot.ini`
3. The default configuration is based on `a-fot.ini`, but arguments can be flexibly configured by running the following command: 
`a-fot [OPTION1 ARG1] [OPTION2 ARG2]`

## Notes

1. You need to prepare the build script (`build_script`) and execution script (`run_script`) for the application. This tool uses the build script to compile the application and the execution script to launch the application for optimization.
2. Currently, this tool only supports optimization for single-instance applications (meaning only one process is running during application execution).
3. Ensure that the application test cases launched by the execution script behave the same as those in the actual production environment. Otherwise, negative optimization may occur.
4. Using A-FOT requires LLVM-BOLT for openEuler-12.3.0-24.12 or later. This version includes additional options not found in the open-source LLVM-BOLT 17.0.6.
