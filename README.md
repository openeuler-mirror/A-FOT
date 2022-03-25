# A-FOT

#### 介绍
A-FOT(automatic feedback-directed optimization tool)是一款用于提升编译器openEuler GCC自动反馈优化特性易用性的工具。
该工具的目标是让用户通过较少的配置即可自动完成反馈优化的相关步骤（包括采样、分析、优化等），降低自动反馈优化特性的使用难度，享受反馈优化带来的性能提升。

#### 环境依赖

1.  编译器： openEuler GCC 10.3.1
2.  架构： x86_64 aarch64

#### 安装教程

1.  git clone https://gitee.com/openeuler/A-FOT.git
2.  yum install -y A-FOT (仅支持openEuler 22.03 LTS)

#### 使用说明

1.  填写配置项：  
`a-fot.ini`
2.  启动优化：  
`a-fot --config_file a-fot.ini`
3.  默认参数配置以a-fot.ini为基础，同时支持参数通过命令行灵活配置：  
`a-fot [OPTION1 ARG1] [OPTION2 ARG2]`

#### 特别提醒：

1. 用户需要自行完成应用的构建脚本（build_script）和执行脚本（run_script）。本工具会使用构建脚本完成应用的构建，使用执行脚本启动被优化的应用
2. 本工具目前仅支持单实例应用优化，即应用在执行时只有一个进程
3. 用户需保证执行脚本启动的应用程序测试用例与实际生产环境行为相同，否则可能会导致负优化
