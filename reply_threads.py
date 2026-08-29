import json, subprocess

replies = [
    ("PRRT_kwDOTyrvCc6dUNDR", "Fixed: replaced grep||echo with sed to update stale PASEO_HOME values in /etc/environment."),
    ("PRRT_kwDOTyrvCc6dUNDU", "Fixed: permission fix now uses ${REMOTE_USER_HOME} instead of hard-coded /home/vscode."),
    ("PRRT_kwDOTyrvCc6dUNDV", "Fixed: changed home dir mode from 2775 to 2755 (group r-x only, no write)."),
    ("PRRT_kwDOTyrvCc6dUNDZ", "Fixed: runtime-bin is now appended to PATH instead of prepended, reducing command-hijacking risk."),
    ("PRRT_kwDOTyrvCc6dUNgC", "Fixed: permission fix now uses ${REMOTE_USER_HOME} consistently."),
    ("PRRT_kwDOTyrvCc6dUNgF", "The || true on all chgrp/chmod commands handles non-root execution. chmod works on owned files; chgrp silently fails (expected). Best-effort for OpenShift random-UID compat."),
    ("PRRT_kwDOTyrvCc6dUOVE", "Fixed: permission fix now targets ${REMOTE_USER_HOME}."),
    ("PRRT_kwDOTyrvCc6dUOVI", "Fixed: using [[ ]] in both permission loops."),
    ("PRRT_kwDOTyrvCc6dUOVO", "Fixed: changed mode from 2775 to 2755 (group r-x, not rwx)."),
]

ADD_REPLY = '''
mutation($thread:ID!,$body:String!){
  addPullRequestReviewThreadReply(input:{pullRequestReviewThreadId:$thread,body:$body}){
    comment{ url }
  }
}
'''
RESOLVE = '''
mutation($thread:ID!){
  resolveReviewThread(input:{threadId:$thread}){
    thread{ isResolved }
  }
}
'''

for tid, body in replies:
    r = subprocess.run(["gh","api","graphql","-f",f"query={ADD_REPLY}","-F",f"thread={tid}","-F",f"body={body}"], capture_output=True, text=True)
    if r.returncode != 0:
        print(f"REPLY FAIL {tid}: {r.stderr[:200]}")
        continue
    r2 = subprocess.run(["gh","api","graphql","-f",f"query={RESOLVE}","-F",f"thread={tid}"], capture_output=True, text=True)
    if r2.returncode != 0:
        print(f"RESOLVE FAIL {tid}: {r2.stderr[:200]}")
    else:
        print(f"OK {tid}")
