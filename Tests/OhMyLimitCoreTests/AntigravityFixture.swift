import Foundation

struct AntigravityFixture: Sendable {
    let directory: URL
    let executable: URL
    init(_ scenario: String = "usage") throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("AntigravityFixture-\(UUID())")
        executable = directory.appendingPathComponent("agy peer ; literal")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        try Data(scenario.utf8).write(to: directory.appendingPathComponent("scenario"))
        try Data(Self.script.utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
    }
    func remove() throws { try FileManager.default.removeItem(at: directory) }
    func launches() throws -> [[String: Any]] {
        try String(contentsOf: directory.appendingPathComponent("launches"), encoding: .utf8).split(separator: "\n").map {
            try JSONSerialization.jsonObject(with: Data($0.utf8)) as! [String: Any]
        }
    }
    func reapedAndCleaned() throws -> Bool {
        try launches().allSatisfy {
            kill(Int32($0["pid"] as! Int), 0) == -1 && errno == ESRCH
                && !FileManager.default.fileExists(atPath: $0["cwd"] as! String)
        }
    }
    private static let script = #"""
#!/usr/bin/python3
import json, os, signal, sys
root = os.path.dirname(os.path.realpath(__file__))
mode = open(os.path.join(root, 'scenario')).read()
with open(os.path.join(root, 'launches'), 'a') as f:
    f.write(json.dumps({'pid':os.getpid(), 'args':sys.argv[1:], 'cwd':os.getcwd(), 'files':os.listdir('.'), 'permissions':os.stat('.').st_mode & 0o777})+'\n')
assert sys.stdin.read() == ''
if sys.argv[1:] == ['--version']:
    print('1.1.10' if mode == 'old' else '1.1.11')
    sys.exit(0)
assert sys.argv[1:] == ['-p', '/usage', '--output-format', 'json', '--print-timeout', '90s']
if mode == 'tree':
    r, w = os.pipe()
    child = os.fork()
    if child == 0:
        os.close(r)
        signal.signal(signal.SIGTERM, signal.SIG_DFL)
        os.write(w, b'R')
        os.close(w)
        while True: signal.pause()
    os.close(w)
    assert os.read(r, 1) == b'R'
    os.close(r)
    with open(os.path.join(root, 'child'), 'w') as f:
        f.write(str(child))
    def terminate_tree(signum, frame):
        os.waitpid(child, 0)
        sys.exit(0)
    signal.signal(signal.SIGTERM, terminate_tree)
    os.write(1, b'R')
    while True: signal.pause()
if mode in ['cancel', 'timeout']:
    signal.signal(signal.SIGTERM, signal.SIG_IGN)
    os.write(1, b'R')
    while True: signal.pause()
if mode == 'graceful':
    def terminated(signum, frame):
        with open(os.path.join(root, 'terminated'), 'w') as f:
            f.write('SIGTERM')
        os._exit(0)
    signal.signal(signal.SIGTERM, terminated)
    os.write(1, b'R')
    while True: signal.pause()
if mode in ['stdout', 'stderr']:
    os.write(1 if mode == 'stdout' else 2, b'x' * (2 * 1024 * 1024))
    sys.exit(0)
if mode == 'error':
    os.write(2, b'token=synthetic-secret')
    sys.exit(7)
print(json.dumps({'status':'SUCCESS','command':{'name':'usage','data':{'groups':[{'buckets':[{'bucket_id':'gemini-5h','remaining_fraction':0.75}]}]}}}))
"""#
}
