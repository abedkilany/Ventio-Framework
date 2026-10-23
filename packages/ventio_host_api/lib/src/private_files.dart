import 'dart:convert';
import 'dart:io';

/// Local Linux delivery/witness storage. Secrets travel only through stdin or
/// private file descriptors, never argv, stdout diagnostics, environment or logs.
/// Parent directory must already belong to this OS account and have mode 0700.
class PrivateFiles {
  static const _script = r'''
import os,sys,stat,tempfile
op,path=sys.argv[1:]
parent=os.path.dirname(os.path.abspath(path))
st=os.lstat(parent)
if not stat.S_ISDIR(st.st_mode) or st.st_uid!=os.geteuid() or st.st_mode & 0o077:
    raise RuntimeError('private directory required')
def check(st):
    if not stat.S_ISREG(st.st_mode) or st.st_uid!=os.geteuid() or st.st_mode & 0o077:
        raise RuntimeError('private regular file required')
if op=='read':
    fd=os.open(path,os.O_RDONLY|os.O_NOFOLLOW)
    check(os.fstat(fd))
    data=os.read(fd,1048577)
    os.close(fd)
    if len(data)>1048576: raise RuntimeError('file too large')
    sys.stdout.buffer.write(data)
else:
    data=sys.stdin.buffer.read(1048577)
    if len(data)>1048576: raise RuntimeError('file too large')
    if op=='replace':
        check(os.lstat(path))
        fd,tmp=tempfile.mkstemp(prefix='.ventio-',dir=parent)
    else:
        fd=os.open(path,os.O_WRONLY|os.O_CREAT|os.O_EXCL|os.O_NOFOLLOW,0o600)
        tmp=path
    try:
        with os.fdopen(fd,'wb') as f:
            f.write(data);f.flush();os.fsync(f.fileno())
        if op=='replace': os.replace(tmp,path)
        dfd=os.open(parent,os.O_RDONLY|os.O_DIRECTORY)
        os.fsync(dfd);os.close(dfd)
    except:
        if op=='replace' and os.path.exists(tmp): os.unlink(tmp)
        raise
''';
  static Future<String> _run(String operation, String path, String data) async {
    if (!Platform.isLinux || !File(path).isAbsolute) {
      throw StateError('Private storage requires an absolute Linux path');
    }
    final process =
        await Process.start('python3', ['-c', _script, operation, path]);
    final output = process.stdout.transform(utf8.decoder).join();
    final errors = process.stderr.drain<void>();
    process.stdin.write(data);
    await process.stdin.close();
    final code = await process.exitCode.timeout(const Duration(seconds: 10));
    await errors;
    if (code != 0) {
      await output;
      throw StateError('Private storage operation failed');
    }
    return output;
  }

  static Future<String> read(String path) => _run('read', path, '');
  static Future<void> create(String path, Object value) async {
    await _run('create', path, jsonEncode(value));
  }

  static Future<void> replace(String path, Object value) async {
    await _run('replace', path, jsonEncode(value));
  }
}
