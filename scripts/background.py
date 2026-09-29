#!/usr/bin/env python3
"""Run a native client on a private 1440p Wayland display, without desktop windows."""
import os
import pathlib
import shlex
import shutil
import signal
import subprocess
import sys
import tempfile


def run(command, *, timeout=None, **kwargs):
    """Capture a private client while giving cancellation time to clean it up."""
    kwargs.pop('capture_output', None)
    process = subprocess.Popen([sys.executable, str(pathlib.Path(__file__).resolve()),
                                '--', *command], stdout=subprocess.PIPE,
                               stderr=subprocess.PIPE, **kwargs)
    try:
        stdout, stderr = process.communicate(timeout=timeout)
    except BaseException:
        process.terminate()
        try:
            process.communicate(timeout=5)
        except subprocess.TimeoutExpired:
            process.kill()
            process.communicate()
        raise
    return subprocess.CompletedProcess(command, process.returncode, stdout, stderr)


def main():
    command = sys.argv[1:]
    if command and command[0] == '--':
        command = command[1:]
    if not command:
        raise SystemExit('Usage: scripts/background.py -- COMMAND [ARGS...]')
    for tool in ('kwin_wayland', 'dbus-run-session'):
        if not shutil.which(tool):
            raise SystemExit(f'Background graphics need installed {tool}; no desktop fallback is used.')
    with tempfile.TemporaryDirectory(prefix='ascii-life-qa-') as temp:
        directory = pathlib.Path(temp)
        runtime = directory / 'runtime'
        runtime.mkdir(mode=0o700)
        config = directory / 'config'
        config.mkdir()
        status = directory / 'client-status'
        pid_path = pathlib.Path(os.environ.get('ASCII_LIFE_PID_FILE', str(directory / 'client-pid')))
        session = directory / 'session'
        session.write_text('#!/bin/sh\n' + shlex.join(command) + ' &\nclient_pid=$!\n'
                           + 'printf "%s\\n" "$client_pid" > ' + shlex.quote(str(pid_path)) + '\n'
                           + 'wait "$client_pid"\nclient_status=$?\n'
                           + 'printf "%s\\n" "$client_status" > ' + shlex.quote(str(status)) + '\n'
                           + 'exit "$client_status"\n')
        session.chmod(0o700)
        env = dict(os.environ)
        env.pop('DISPLAY', None)
        env.pop('WAYLAND_DISPLAY', None)
        env['QT_QPA_PLATFORM'] = 'offscreen'
        env['XDG_RUNTIME_DIR'] = str(runtime)
        env['XDG_CONFIG_HOME'] = str(config)
        # Each compositor has its own session bus and runtime/config directories.
        # --virtual never creates a nested window or opens a physical output.
        process = subprocess.Popen(['dbus-run-session', '--', 'kwin_wayland', '--virtual',
                                 '--width', '2560', '--height', '1440', '--socket', 'wayland-ascii-life',
                                 '--no-lockscreen', '--no-global-shortcuts', '--no-kactivities',
                                 '--exit-with-session', str(session)], env=env, start_new_session=True)
        def interrupted(signum, _frame):
            raise SystemExit(128 + signum)

        old_handlers = {sig: signal.signal(sig, interrupted) for sig in (signal.SIGTERM, signal.SIGINT)}
        try:
            returncode = process.wait()
        finally:
            for sig, handler in old_handlers.items():
                signal.signal(sig, handler)
            # The private bus, compositor and game share this process group.
            # Also reap any remaining children after a client failure or timeout.
            try:
                os.killpg(process.pid, signal.SIGTERM)
            except ProcessLookupError:
                pass
            try:
                process.wait(timeout=2)
            except subprocess.TimeoutExpired:
                os.killpg(process.pid, signal.SIGKILL)
                process.wait()
        if not status.exists():
            raise SystemExit(returncode or 1)
        raise SystemExit(int(status.read_text().strip()))


if __name__ == '__main__':
    main()
