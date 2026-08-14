module HostBootstrap.Ensure.Colima.Backend.Program.LiveDocker
  ( liveDockerProgram,
    validLiveDockerArguments,
  )
where

import HostBootstrap.Ensure.Colima.Backend.Program.Common (commonProgram)

-- Docker is routed only while the exact profile lock, managed record inode,
-- machine identity, context fingerprint, and isolated config-directory inode
-- all remain live.  Arbitrary command output is length-framed after the final
-- revalidation; it can never be mistaken for an authority report.
liveDockerProgram :: String
liveDockerProgram =
  unlines commonProgram
    ++ unlines
      [ "colima,docker,lima,profile,lock_path,state_root,record,expected_owner,expected_invocation,expected_nonce,expected_machine,expected_context,expected_epoch_raw,expected_cpu_raw,expected_memory_raw,expected_data_raw,expected_root_raw,expected_artifacts,lock_device_raw,lock_inode_raw,record_device_raw,record_inode_raw,docker_device_raw,docker_inode_raw,colima_device_raw,colima_inode_raw,disk_device_raw,disk_inode_raw,expected_chain_raw,timeout_raw,*docker_args=sys.argv[1:]",
        "expected_epoch=uint(expected_epoch_raw,True); expected_cpu=uint(expected_cpu_raw,True); expected_memory=uint(expected_memory_raw,True); expected_data=uint(expected_data_raw,True); expected_root=uint(expected_root_raw,True); lock_device=uint(lock_device_raw); lock_inode=uint(lock_inode_raw,True); record_device=uint(record_device_raw); record_inode=uint(record_inode_raw,True); docker_device=uint(docker_device_raw); docker_inode=uint(docker_inode_raw,True); colima_device=uint(colima_device_raw); colima_inode=uint(colima_inode_raw,True); disk_device=uint(disk_device_raw); disk_inode=uint(disk_inode_raw,True); expected_chain=parse_chain(expected_chain_raw); command_timeout=uint(timeout_raw,True)",
        "if not valid_owner(expected_owner) or not valid_nonce(expected_invocation) or not valid_nonce(expected_nonce) or not valid_machine(expected_machine) or not valid_nonce(expected_context) or re.fullmatch(r'[0-9a-f]{64}',expected_artifacts) is None or None in (expected_epoch,expected_cpu,expected_memory,expected_data,expected_root,lock_device,lock_inode,record_device,record_inode,docker_device,docker_inode,colima_device,colima_inode,disk_device,disk_inode,expected_chain,command_timeout): finish('CONFLICT authority-format')",
        "expected_wall=(expected_cpu,expected_memory,expected_data,expected_root)",
        "if re.fullmatch(r'h-[0-9a-f]{6}',profile) is None: finish('CONFLICT profile')",
        "routing_exact={'-c','-H','--context','--host','--config','--tls','--tlsverify','--tlscacert','--tlscert','--tlskey'}",
        "routing_prefix=('-c','-H','--context=','--host=','--config=','--tls=','--tlsverify=','--tlscacert=','--tlscert=','--tlskey=')",
        "if not docker_args or docker_args[0].startswith('-') or docker_args[0] in {'context','login','logout','buildx'}: finish('CONFLICT docker-command-shape')",
        "if any(value in routing_exact or any(value.startswith(prefix) for prefix in routing_prefix) for value in docker_args): finish('CONFLICT docker-routing-argument')",
        "expected_lock=(lock_device,lock_inode); expected_record=(record_device,record_inode); expected_docker=(docker_device,docker_inode); expected_colima=(colima_device,colima_inode); expected_disk=(disk_device,disk_inode)",
        "lock_root=os.path.dirname(lock_path); lock_root_descriptor,lock_chain=open_directory(lock_root,'lock-root')",
        "lock_descriptor=open_lock(lock_root,lock_root_descriptor,lock_path,False,expected_lock); validate_lock_empty(lock_descriptor)",
        "root_descriptor,root_chain=open_directory(state_root,'state-root')",
        "state_directory,state_descriptor,record_name,opened_state_chain,docker_descriptor,docker_identity,docker_created=ensure_state_directory(state_root,root_descriptor,root_chain,record,False,os.environ.get('DOCKER_CONFIG',''))",
        "state_directory_chain=[entry for entry in opened_state_chain if docker_descriptor is None or entry[1] != docker_descriptor]",
        "colima_parent,colima_name,colima_parent_descriptor,colima_chain,colima_descriptor,colima_identity=open_colima_home(os.environ.get('COLIMA_HOME',''))",
        "state_chain=lock_chain+state_directory_chain+colima_chain",
        "if docker_descriptor is not None: state_chain.append((os.environ.get('DOCKER_CONFIG',''),docker_descriptor,state_descriptor,record_name+'.docker'))",
        "if docker_descriptor is None or docker_identity != expected_docker: finish('CONFLICT docker-identity')",
        "if colima_descriptor is None or colima_identity != expected_colima: finish('CONFLICT colima-home-identity')",
        "def command(stage,args): return bounded_command(stage,args,command_timeout,lock_descriptor,lock_path,state_chain,expected_lock)",
        "def validate_owned():",
        "    validate_colima_home_marker(colima_descriptor,expected_owner,expected_nonce,expected_colima)",
        "    final,stages=load_protocol_state(record_name,state_descriptor,expected_owner,expected_invocation,docker_descriptor)",
        "    if final is None: finish('CONFLICT record-missing')",
        "    descriptor,parsed=final",
        "    if parsed.state != 'managed' or parsed.owner != expected_owner or parsed.invocation != expected_invocation or parsed.nonce != expected_nonce or parsed.machine != expected_machine or parsed.context != expected_context or parsed.epoch != expected_epoch or parsed.lock != expected_lock or parsed.record != expected_record or parsed.docker != expected_docker or parsed.colima != expected_colima or parsed.disk != expected_disk or parsed.wall != expected_wall or parsed.artifacts != expected_artifacts or parsed.chain != tuple(expected_chain) or set(stages)-{'reserved'}: finish('CONFLICT record-mismatch')",
        "    os.close(descriptor)",
        "    raw=command('list',[colima,'list','--json'])",
        "    if raw.returncode != 0: finish('FAILED list')",
        "    matches=[value for value in strict_colima_values(raw) if value.get('name') == profile]",
        "    if len(matches) != 1 or type(matches[0].get('status')) is not str or matches[0].get('status').lower() != 'running' or not exact_wall(matches[0],expected_cpu,expected_memory,expected_data): finish('CONFLICT profile-state')",
        "    machine,epoch_value=read_machine(command,profile)",
        "    if machine != expected_machine or epoch_value != expected_epoch: finish('CONFLICT identity-mismatch')",
        "    if context_fingerprint(command,docker,'colima-'+profile,docker_descriptor) != expected_context: finish('CONFLICT docker-context-identity')",
        "    artifacts=observe_profile_artifacts(command,lima,profile,os.environ.get('COLIMA_HOME',''),colima_descriptor,expected_wall)",
        "    if artifacts is None or artifacts.disk != expected_disk or artifacts.digest != expected_artifacts: finish('CONFLICT disk-identity')",
        "    validate_chain_identity(state_chain+artifacts.chain,expected_chain); validate_artifact_entries(artifacts.entries)",
        "    close_artifact_entries(artifacts.entries)",
        "    for entry in reversed(artifacts.chain): os.close(entry[1])",
        "validate_owned()",
        "result=command('docker',[docker,'--context','colima-'+profile]+docker_args)",
        "validate_owned()",
        "header='DOCKER '+str(result.returncode)+' '+str(len(result.stdout))+' '+str(len(result.stderr))+'\\n'",
        "sys.stdout.write(header+result.stdout+result.stderr); sys.stdout.flush(); raise SystemExit(0)"
      ]

-- | Docker accepts persistent connection flags in several argv positions.
-- Reject every spelling before entering the backend; the embedded process
-- repeats the check so a future caller of the private facade cannot weaken it.
validLiveDockerArguments :: [String] -> Bool
validLiveDockerArguments arguments =
  case arguments of
    command : _ -> validCommand command && all validArgument arguments
    [] -> False
  where
    validCommand command =
      case command of
        initial : _ ->
          initial /= '-'
            && command `notElem` ["context", "login", "logout", "buildx"]
        [] -> False
    validArgument value =
      value `notElem` exactOverrides
        && not (any (`prefixOf` value) attachedOverrides)
    exactOverrides =
      [ "-c",
        "-H",
        "--context",
        "--host",
        "--config",
        "--tls",
        "--tlsverify",
        "--tlscacert",
        "--tlscert",
        "--tlskey"
      ]
    attachedOverrides =
      [ "-c",
        "-H",
        "--context=",
        "--host=",
        "--config=",
        "--tls=",
        "--tlsverify=",
        "--tlscacert=",
        "--tlscert=",
        "--tlskey="
      ]
    prefixOf prefix value = take (length prefix) value == prefix
