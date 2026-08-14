module HostBootstrap.Ensure.Colima.Backend.Program.Supervisor
  ( commandSupervisorProgram,
  )
where

-- The backend process is itself owned by the Haskell runner's process group,
-- but each Colima/Docker command needs a separately killable group for its
-- shorter deadline.  This small supervisor is that group leader.  Its stdin
-- is a parent-death pipe: if the owning backend is killed without running its
-- Python signal handler, EOF makes the supervisor kill its whole group before
-- the named tool or any descendant can survive the ownership bracket.
commandSupervisorProgram :: String
commandSupervisorProgram =
  unlines
    [ "import errno,os,selectors,signal,subprocess,sys,time",
      "tool=sys.argv[1:]",
      "if not tool: raise SystemExit(125)",
      "leader_done=False",
      "def child_changed(_signal,_frame):",
      "    global leader_done; leader_done=True",
      "signal.signal(signal.SIGCHLD,child_changed)",
      "try: child=subprocess.Popen(tool,stdin=subprocess.DEVNULL,stdout=subprocess.PIPE,stderr=subprocess.PIPE,close_fds=True,start_new_session=True)",
      "except OSError: raise SystemExit(126)",
      "child_reaped=False",
      "def signal_child_group(value):",
      "    try: os.killpg(child.pid,value)",
      "    except (ProcessLookupError,PermissionError): pass",
      "def terminate_child_group():",
      "    signal_child_group(signal.SIGTERM); time.sleep(0.1); signal_child_group(signal.SIGKILL)",
      "def terminate_and_reap():",
      "    global child_reaped",
      "    if child_reaped: return child.returncode",
      "    terminate_child_group()",
      "    try: value=child.wait(timeout=2)",
      "    except subprocess.TimeoutExpired: return None",
      "    child_reaped=True; return value",
      "def stop(_signal,_frame):",
      "    terminate_and_reap()",
      "    raise SystemExit(128)",
      "signal.signal(signal.SIGTERM,stop); signal.signal(signal.SIGINT,stop)",
      "def relay(descriptor,data):",
      "    offset=0",
      "    while offset < len(data):",
      "        written=os.write(descriptor,data[offset:])",
      "        if written <= 0: raise BrokenPipeError()",
      "        offset += written",
      "selected=selectors.DefaultSelector()",
      "selected.register(sys.stdin.buffer,selectors.EVENT_READ,0)",
      "selected.register(child.stdout,selectors.EVENT_READ,1)",
      "selected.register(child.stderr,selectors.EVENT_READ,2)",
      "open_streams=2",
      "try:",
      "    while open_streams or not leader_done:",
      "        for key,_events in selected.select(0.2):",
      "            try: chunk=os.read(key.fileobj.fileno(),16384)",
      "            except BlockingIOError: continue",
      "            if key.data == 0:",
      "                if not chunk: stop(signal.SIGKILL,None)",
      "            elif chunk:",
      "                try: relay(key.data,chunk)",
      "                except BrokenPipeError: stop(signal.SIGKILL,None)",
      "            else:",
      "                selected.unregister(key.fileobj); key.fileobj.close(); open_streams -= 1",
      "    returncode=terminate_and_reap()",
      "    if returncode is None: raise SystemExit(124)",
      "finally:",
      "    if not child_reaped: terminate_and_reap()",
      "    selected.close()",
      "raise SystemExit(returncode if 0 <= returncode <= 255 else 128+abs(returncode))"
    ]
