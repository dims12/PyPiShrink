import threading
from getpass import getpass
import subprocess
import sys
from typing import Optional
import os

password: Optional[str] = None


def ask_password_if_required():
    global password

    if password is None:
        login = os.getlogin()
        password = getpass(f"[sudo] password for {login}: ")

    return password


def exec(command: str, sudo: bool = False, out_lines: list = None, err_lines: list = None, assert_error: bool = True, mute_out: bool = False, mute_err: bool = False):
    def reader_thread(pipe, func, proc):
        buffer = bytearray()
        while True:
            chunk = pipe.read(1)  # Reading one byte
            if chunk:
                buffer.extend(chunk)
                try:
                    text = buffer.decode('utf-8')
                    func(text)
                    buffer.clear()
                except UnicodeDecodeError:
                    # Incomplete character, continue reading into buffer
                    pass

            elif proc.poll() is not None:
                break

    def capture(text, file, mute, chars: list):
        if not mute:
            print(text, end='', file=file)
        chars.append(text)

    out_chars = []
    err_chars = []

    global password

    if sudo:

        print(f"$ sudo {command}")

        ask_password_if_required()

        process = subprocess.Popen(f"echo {password} | sudo -S {command}", shell=True,
                                   stdin=subprocess.PIPE,
                                   stdout=subprocess.PIPE,
                                   stderr=subprocess.PIPE,
                                   bufsize=0)
    else:

        print(f"$ '{command}'")

        process = subprocess.Popen(command, shell=True,
                                   stdin=subprocess.PIPE,
                                   stdout=subprocess.PIPE,
                                   stderr=subprocess.PIPE,
                                   bufsize=0)

    out_reader_thread = threading.Thread(target=reader_thread,
                                         args=[process.stdout, lambda text: capture(text, sys.stdout, mute_out, out_chars),
                                               process])
    out_reader_thread.start()

    err_reader_thread = threading.Thread(target=reader_thread,
                                         args=[process.stderr, lambda text: capture(text, sys.stderr, mute_err, err_chars),
                                               process])
    err_reader_thread.start()

    out_reader_thread.join()
    err_reader_thread.join()

    out_string = ''.join(out_chars)
    err_string = ''.join(err_chars)

    if out_lines is not None:
        out_lines.extend(out_string.split("\n"))

    if err_lines is not None:
        err_lines.extend(err_string.split("\n"))

    if process.poll() and assert_error:
        raise ValueError(process.poll())

    return out_string.strip()
