#!/usr/bin/python
import argparse
import os
import sys
from typing import TextIO, Dict, Type

from src.prefix_tree.tree import PrefixTree
from src.formaters import BaseFormater, ALL_FORMATERS


def stream_to_regexp(stream: TextIO, formatter: BaseFormater) -> str:
    lines_generator = (line for line in stream.read().split(os.linesep) if line)
    prefix_tree = PrefixTree(lines_generator)
    return prefix_tree.to_regexp(formatter)


FORMATERS_BY_CODE: Dict[str, Type[BaseFormater]] = {
    formater.code(): formater
    for formater in ALL_FORMATERS
}


def main():
    parser = argparse.ArgumentParser(
        description='w2re: Words to Regular Expression, script for '
                    'converting a list of words into compressed regular '
                    'expression. Empty lines are ignored.',
        formatter_class=argparse.RawTextHelpFormatter
    )

    formats_list = '\n'.join(
        "%s:\t%s" % (key, formater.description())
        for key, formater in FORMATERS_BY_CODE.items()
    )

    default_formatter_code = ALL_FORMATERS[0].code()

    parser.add_argument(
        '-f',
        dest='formater',
        default=default_formatter_code,
        metavar='<type>',
        choices=tuple(FORMATERS_BY_CODE.keys()),
        help="Output format. Possible value are:\n\n{}\n\nDefault value is '{}'.".format(
            formats_list, default_formatter_code
        )
    )

    parser.add_argument(
        '-i', dest='input', default=sys.stdin, metavar='<filename>',
        help='Input file. If none specified, stdin will be used instead.'
    )

    args = parser.parse_args()

    print(stream_to_regexp(args.input, FORMATERS_BY_CODE[args.formater]))


if __name__ == '__main__':
    main()