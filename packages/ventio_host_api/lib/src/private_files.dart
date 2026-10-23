import 'dart:convert';
import 'dart:io';

/// Local Linux delivery/witness storage. Secrets travel only through stdin or
/// private file descriptors, never argv, stdout diagnostics, environment or logs.
/// Credential directories are owner-only 0700. Explicit authority operations
/// support a writer-owned 0750 directory and group-read-only 0640 witness.
class PrivateFiles {
  static const _script = r'''import os,sys,stat,tempfile
op,path,owner,gid=sys.argv[1:]
owner=int(owner);gid=int(gid)
witness=op.startswith('witness-')
runtime=op=='witness-read-runtime'
op=op.replace('witness-','').replace('-runtime','')
parent=os.path.dirname(os.path.abspath(path))
if os.path.realpath(parent)!=parent: raise RuntimeError('symlink ancestor refused')
st=os.lstat(parent)
expected=owner if runtime else os.geteuid()
mask=0o027 if witness else 0o077
if not stat.S_ISDIR(st.st_mode) or st.st_uid!=expected or st.st_mode & mask:
    raise RuntimeError('protected directory required')
if runtime and (expected==os.geteuid() or os.access(parent,os.W_OK)):
    raise RuntimeError('Host must not control witness directory')
def check(st):
    if not stat.S_ISREG(st.st_mode) or st.st_uid!=expected or st.st_mode & mask:
        raise RuntimeError('protected regular file required')
if op=='read':
    # NONBLOCK avoids hanging before fstat on a FIFO/device supplied by mistake.
    fd=os.open(path,os.O_RDONLY|os.O_NOFOLLOW|os.O_NONBLOCK)
    check(os.fstat(fd))
    if runtime and os.access(path,os.W_OK): raise RuntimeError('Host can write witness')
    data=os.read(fd,1048577);os.close(fd)
    if len(data)>1048576: raise RuntimeError('file too large')
    sys.stdout.buffer.write(data)
else:
    data=sys.stdin.buffer.read(1048577)
    if len(data)>1048576: raise RuntimeError('file too large')
    mode=0o640 if witness and gid>=0 and op!='lock' else 0o600
    if op=='replace':
        previous=os.lstat(path);check(previous)
        mode=stat.S_IMODE(previous.st_mode);gid=previous.st_gid
        fd,tmp=tempfile.mkstemp(prefix='.ventio-',dir=parent)
    else:
        fd=os.open(path,os.O_WRONLY|os.O_CREAT|os.O_EXCL|os.O_NOFOLLOW,mode)
        tmp=path
    try:
        os.fchmod(fd,mode)
        if gid>=0: os.fchown(fd,-1,gid)
        with os.fdopen(fd,'wb') as f:
            f.write(data);f.flush();os.fsync(f.fileno())
        if op=='replace': os.replace(tmp,path)
        dfd=os.open(parent,os.O_RDONLY|os.O_DIRECTORY);os.fsync(dfd);os.close(dfd)
    except:
        if op=='replace' and os.path.exists(tmp): os.unlink(tmp)
        raise
''';
  static Future<String> _run(String operation, String path, String data,
      {int ownerUid = -1, int readerGid = -1}) async {
    if (!Platform.isLinux || !File(path).isAbsolute) {
      throw StateError('Private storage requires an absolute Linux path');
    }
    final process = await Process.start(
        'python3', ['-c', _script, operation, path, '$ownerUid', '$readerGid']);
    final output = process.stdout.transform(utf8.decoder).join();
    final errors = process.stderr.drain<void>();
    Future<String> perform() async {
      process.stdin.write(data);
      await process.stdin.close();
      final code = await process.exitCode;
      await errors;
      final result = await output;
      if (code != 0) throw StateError('Private storage operation failed');
      return result;
    }

    try {
      return await perform().timeout(const Duration(seconds: 10));
    } catch (_) {
      process.kill(ProcessSignal.sigkill);
      await process.exitCode.timeout(const Duration(seconds: 2));
      // Drain after termination. Never leave a timed-out helper running or
      // expose interpreter exception text / secret contents to callers.
      await errors;
      await output;
      throw StateError('Private storage operation failed');
    }
  }

  static Future<String> readAuthority(String path, {int? trustedOwnerUid}) =>
      _run(trustedOwnerUid == null ? 'witness-read' : 'witness-read-runtime',
          path, '',
          ownerUid: trustedOwnerUid ?? -1);
  static Future<void> createAuthority(String path, Object value, int gid,
      {bool lock = false}) async {
    await _run(
        lock ? 'witness-lock' : 'witness-create', path, jsonEncode(value),
        readerGid: gid);
  }

  static Future<void> replaceAuthority(
      String path, Object value, int gid) async {
    await _run('witness-replace', path, jsonEncode(value), readerGid: gid);
  }

  static Future<String> read(String path) => _run('read', path, '');
  static Future<void> create(String path, Object value) async {
    await _run('create', path, jsonEncode(value));
  }

  static Future<void> replace(String path, Object value) async {
    await _run('replace', path, jsonEncode(value));
  }
}
