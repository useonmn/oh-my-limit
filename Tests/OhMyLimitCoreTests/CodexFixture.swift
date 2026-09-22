import Foundation

/// A real executable peer. All state and protocol data are synthetic and local.
struct CodexFixture: Sendable {
    let directory: URL
    let executable: URL
    let home: URL

    init(_ scenario: String = "usage") throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("CodexFixture-\(UUID())")
        home = directory.appendingPathComponent("home with spaces ; literal")
        executable = directory.appendingPathComponent("Codex peer ; literal")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        try Data(scenario.utf8).write(to: home.appendingPathComponent("CodexScenario"))
        try Data(Self.script.utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
    }

    func remove() throws { try FileManager.default.removeItem(at: directory) }

    func assertReaped() throws -> Bool {
        let pid = try String(contentsOf: home.appendingPathComponent("CodexPID"), encoding: .utf8)
        return kill(Int32(pid)!, 0) == -1 && errno == ESRCH
    }

    func requests() throws -> [[String: Any]] {
        let data = try String(contentsOf: home.appendingPathComponent("CodexRequests"), encoding: .utf8)
        return try data.split(separator: "\n").map {
            try JSONSerialization.jsonObject(with: Data($0.utf8)) as! [String: Any]
        }
    }

    static let script = #"""
#!/usr/bin/python3
import json, os, signal, sys
home = os.environ['CODEX_HOME']
mode = open(os.path.join(home, 'CodexScenario')).read()
open(os.path.join(home, 'CodexPID'), 'w').write(str(os.getpid()))
open(os.path.join(home, 'CodexLaunch'), 'w').write(json.dumps({'args':sys.argv[1:], 'home':home, 'path':os.environ.get('PATH')}))
if mode == 'cancel':
    signal.signal(signal.SIGTERM, signal.SIG_IGN)

def send(value):
    data = (json.dumps(value, separators=(',', ':')) + '\n').encode()
    # Split every response across writes; no sleeps or timing-dependent coordination.
    for start in range(0, len(data), 7):
        os.write(1, data[start:start+7])

def result(req, value): send({'id':req['id'], 'result':value})
def completed(login, success):
    send({'method':'account/login/completed','params':{'loginId':login,'success':success,'error':'sensitive backend text'}})

initialized = False
for line in sys.stdin:
    req = json.loads(line)
    with open(os.path.join(home, 'CodexRequests'), 'a') as log:
        log.write(json.dumps(req) + '\n')
    method = req['method']
    if method == 'initialize':
        if mode == 'eof': sys.exit(17)
        if mode == 'partialEOF':
            os.write(1, b'{"id":'); sys.exit(18)
        if mode == 'malformed':
            os.write(1, b'not-json\n'); continue
        if mode == 'oversize':
            os.write(1, b'x' * (2 * 1024 * 1024)); continue
        if mode == 'stderr':
            os.write(2, b'secret' * (400 * 1024))
        if mode == 'serverError':
            send({'id':req['id'],'error':{'code':-32000,'message':'token=secret https://auth.openai.com/private'}}); continue
        send({'id':999999, 'result':{'wrong':True}})
        send({'method':'unrelated/notification','params':{}})
        send({'id':str(req['id']), 'result':{'wrong':True}})
        send({'id':True, 'result':{'wrong':True}})
        result(req, {'userAgent':'CodexFixture'})
    elif method == 'initialized':
        assert 'id' not in req
        initialized = True
    elif method == 'account/read':
        assert initialized
        if mode == 'apiKey': result(req, {'account':{'type':'apiKey'}})
        elif mode == 'loggedOut': result(req, {'account':None})
        else: result(req, {'account':{'type':'chatgpt','email':'fixture@example.invalid','planType':'plus'}})
    elif method == 'account/rateLimits/read':
        assert initialized
        primary = {'usedPercent':125.5, 'windowDurationMins':300, 'resetsAt':1800000000}
        if mode == 'negative': primary['usedPercent'] = -1
        bucket = {'primary':primary, 'secondary':None, 'credits':{'balance':'12.50','hasCredits':True,'unlimited':False}}
        if mode == 'legacy': result(req, {'rateLimits':bucket})
        else: result(req, {'accountId':'fixture-account','ordinaryUsageAllowed':False,'rateLimits':bucket,'rateLimitsByLimitId':{'codex':bucket,'other':{'limitName':'Server Bucket','primary':{'usedPercent':40,'windowDurationMins':60},'secondary':None}}})
        if mode == 'usageExit': sys.exit(0)
    elif method == 'account/login/start':
        assert initialized and req['params']['type'] == 'chatgpt'
        completed('unrelated', False)
        if mode == 'loginEarly': completed('fixture-login', True)
        url = 'https://auth.openai.com/oauth/authorize?state=fixture'
        if mode == 'unsafeURL': url = 'https://auth.openai.com.evil.invalid/oauth/authorize'
        result(req, {'type':'chatgpt','loginId':'fixture-login','authUrl':url})
        if mode == 'cancel':
            while True: signal.pause()
        if mode != 'loginEarly': completed('fixture-login', mode != 'loginFailure')
    else:
        raise AssertionError('Unexpected RPC method')
"""#
}
