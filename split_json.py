#!/usr/bin/env python3
# _*_ coding:utf-8 _*_


"""
    Copyright@2022-2022, All rights reserved, Powered by: Huawei Tech.Co.,Ltd.

split_json is a interface to split compile commands according to its execution result.

It will generate a new JSON file for the failed compile commands and remove these commands from source file.

Input:
    compile commands json
Output:
    compile commands json including commands which has been successfully executed.
    compile commands json including commands which executed unsuccessfully.

"""
__author__ = 'z00500762'

import argparse
import os
import json
import sys
import logging


class SplitJson:
    compile_commands_success = list()
    compile_commands_fail = list()

    def __init__(self, input_json):
        self.input = input_json

    @staticmethod
    def validate(execution):
        if "arguments" not in execution:
            return False
        if "directory" not in execution:
            return False
        if "exec_result" not in execution:
            return False
        return True

    def get_compile_commands(self):
        compile_commands = list()
        try:
            with open(self.input, "r", encoding='utf-8', errors='ignore') as json_file:
                compile_commands = json.load(json_file)
                if len(compile_commands) == 0:
                    logging.info("compile commands json file is empty: %s", self.input)
        except IOError as exception:
            logging.error("open compile commands json file failed: %s", exception)
        except json.decoder.JSONDecodeError as exception:
            logging.error("json decode file failed: %s", exception)

        return compile_commands

    def split_commands(self):
        compile_commands = self.get_compile_commands()
        for item in compile_commands:
            if not self.validate(item):
                logging.info("discard invalid commands: %s", str(item))
            if not item.get("rebuild"):
                self.compile_commands_success.append(item)
            else:
                self.compile_commands_fail.append(item)
        self.write_json()

    def write_json(self):
        compile_commands_success_file = os.path.splitext(self.input)[0] + ".json"
        compile_commands_fail_file = os.path.splitext(self.input)[0] + ".fail.json"
        with open(compile_commands_success_file, 'w+') as fw:
            json.dump(self.compile_commands_success, fw, sort_keys=False, indent=4)

        with open(compile_commands_fail_file, 'w+') as fw:
            json.dump(self.compile_commands_fail, fw, sort_keys=False, indent=4)


def main(input_json):
    if not os.path.isabs(input_json):
        input_json = os.path.join(os.getcwd(), input_json)
    if not os.path.exists(input_json):
        logging.error("compile_command_file not exists : %s", input_json)
        return -1

    sj = SplitJson(input_json)
    sj.split_commands()


if __name__ == "__main__":
    cmd_parser = argparse.ArgumentParser(description="split compile commands json")
    cmd_parser.add_argument(
        '-i', '--input', dest='input_json', metavar='store', action='store',
        help='json to split'
    )
    args = cmd_parser.parse_args()
    sys.exit(main(args.input_json))
