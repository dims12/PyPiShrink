import subprocess
import sys
import json
import os
import asyncio
import threading
from queue import Queue
from threading import Thread
import select

ON_POSIX = 'posix' in sys.builtin_module_names


def quote(s: str) -> str:
    s = s.replace("\\", "\\\\")
    s = s.replace("$", "\$")
    s = s.replace("\"", "\\\"")
    s = "\"" + s + "\""
    return s


def enqueue_output(out, queue, file):
    for line in iter(out.readline, b''):
        line = line.decode().strip()
        # if line == "":
        #     break
        queue.put(line)
        if file is not None:
            print(line, file=file)
    out.close()


def execute_command(cmd: str, cwd: str = None, show_stdout: bool = True, show_stderr: bool = True, timeout: int = None):
    if cwd is not None:
        cmd = 'cd "%s" && %s' % (cwd, cmd)

    p = subprocess.Popen(cmd, shell=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)

    stdout_queue = Queue()
    stdout_thread = Thread(target=enqueue_output, args=(p.stdout, stdout_queue, sys.stdout if show_stdout else None))
    stdout_thread.start()

    stderr_queue = Queue()
    stderr_thread = Thread(target=enqueue_output, args=(p.stderr, stderr_queue, sys.stderr if show_stderr else None))
    stderr_thread.start()

    return_code = p.wait(timeout=timeout)

    if return_code:
        # raise ValueError("\n".join(stderr))
        raise ValueError()

    res = []
    while not stdout_queue.empty():
        res.append(stdout_queue.get())

    return res

    pass


def parted_get(image: str, partno: int):
    pass
