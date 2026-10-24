' Polls camera snapshot URLs into tmp:/ files without blocking. Each job
' (one per camera) has at most one request in flight, so a slow camera never
' holds up the others, and at most maxInFlight requests run at once, most
' overdue first. Driven by SnapshotTask:
'
'   poller = NewSnapshotPoller(port)
'   poller.setJobs([{ key, url, user, pass, intervalMs }])
'   loop: frames = poller.tick()   and   frame = poller.handle(roUrlEvent)
'
' Frames are { key, ok, uri, error }; uri is a new file each time so Poster
' nodes never show a cached image.

function NewSnapshotPoller(port as Object) as Object
    clock = CreateObject("roTimespan")
    clock.Mark()
    return {
        port: port
        clock: clock
        timeoutMs: 10000
        maxInFlight: 6
        ' tmp:/ lives in RAM. Two files per camera: the one on screen and the
        ' one loading behind it.
        keepFiles: 2
        jobs: {}
        byTransfer: {}
        setJobs: SnapshotPollerSetJobs
        tick: SnapshotPollerTick
        handle: SnapshotPollerHandle
        stopAll: SnapshotPollerStopAll
    }
end function

sub SnapshotPollerSetJobs(list as Object)
    wanted = {}
    for each job in list
        if StrOrEmpty(job.url) <> "" then wanted[job.key] = job
    end for

    for each key in m.jobs.Keys()
        state = m.jobs[key]
        if not wanted.DoesExist(key) or wanted[key].url <> state.job.url then
            SnapshotPollerDrop(m, key)
        end if
    end for

    for each key in wanted
        if m.jobs.DoesExist(key) then
            ' Same URL: keep the state (auth mode, files), take new settings.
            m.jobs[key].job = wanted[key]
        else
            m.jobs[key] = { job: wanted[key], seq: 0, dueAt: 0, xfer: invalid, file: "", startedAt: 0, basic: false, flipped: false, failures: 0, files: [] }
        end if
    end for
end sub

' Starts requests that are due and gives up on ones that hang.
' Returns frames for timed out requests.
function SnapshotPollerTick() as Object
    frames = []
    now = m.clock.TotalMilliseconds()
    inFlight = 0
    due = []
    for each key in m.jobs
        state = m.jobs[key]
        if state.xfer <> invalid then
            if now - state.startedAt > m.timeoutMs then
                state.xfer.AsyncCancel()
                m.byTransfer.Delete(state.xfer.GetIdentity().ToStr())
                state.xfer = invalid
                DeleteFile(state.file)
                frames.Push(SnapshotPollerFailed(state, key, "Snapshot timed out", now))
            else
                inFlight = inFlight + 1
            end if
        else if now >= state.dueAt then
            due.Push({ key: key, dueAt: state.dueAt })
        end if
    end for

    ' Fill free slots with the most overdue jobs so no camera starves.
    while inFlight < m.maxInFlight and due.Count() > 0
        best = 0
        for i = 1 to due.Count() - 1
            if due[i].dueAt < due[best].dueAt then best = i
        end for
        key = due[best].key
        due.Delete(best)
        SnapshotPollerStart(m, m.jobs[key], key, now)
        inFlight = inFlight + 1
    end while
    return frames
end function

' Handles a roUrlEvent. Returns a frame, or invalid when the event was not
' ours or a retry was scheduled.
function SnapshotPollerHandle(msg as Object) as Dynamic
    id = msg.GetSourceIdentity().ToStr()
    key = m.byTransfer[id]
    if key = invalid then return invalid
    m.byTransfer.Delete(id)
    state = m.jobs[key]
    if state = invalid then return invalid
    state.xfer = invalid
    now = m.clock.TotalMilliseconds()
    code = msg.GetResponseCode()

    if code = 200 then
        state.files.Push(state.file)
        while state.files.Count() > m.keepFiles
            DeleteFile(state.files.Shift())
        end while
        state.failures = 0
        state.flipped = false
        interval = AsInt(state.job.intervalMs, 3000)
        state.dueAt = state.startedAt + interval
        return { key: key, ok: true, uri: state.file, error: "" }
    end if

    DeleteFile(state.file)
    if code = 401 and StrOrEmpty(state.job.user) <> "" and not state.flipped then
        ' Roku only answers Digest challenges; cameras that want Basic get it
        ' sent preemptively instead. Try the other mode once, right away.
        state.basic = not state.basic
        state.flipped = true
        state.dueAt = 0
        return invalid
    end if
    state.flipped = false

    reason = "Snapshot failed (HTTP " + code.ToStr() + ")"
    if code = 401 then reason = "Snapshot login rejected"
    if code <= 0 then reason = "Snapshot failed: " + StrOrEmpty(msg.GetFailureReason())
    return SnapshotPollerFailed(state, key, reason, now)
end function

sub SnapshotPollerStopAll()
    for each key in m.jobs.Keys()
        SnapshotPollerDrop(m, key)
    end for
end sub

' ---------------------------------------------------------------- private

sub SnapshotPollerStart(poller as Object, state as Object, key as String, now as Integer)
    job = state.job
    xfer = HttpNewTransfer({ url: job.url, user: job.user, pass: job.pass, basicAuth: state.basic })
    xfer.SetMessagePort(poller.port)
    state.seq = state.seq + 1
    state.file = "tmp:/snap_" + SafeKey(key) + "_" + state.seq.ToStr() + ".jpg"
    state.startedAt = now
    if xfer.AsyncGetToFile(state.file) then
        state.xfer = xfer
        poller.byTransfer[xfer.GetIdentity().ToStr()] = key
    else
        state.dueAt = now + 5000
    end if
end sub

function SnapshotPollerFailed(state as Object, key as String, reason as String, now as Integer) as Object
    state.failures = state.failures + 1
    ' Back off on repeated failures so offline cameras cost almost nothing.
    delay = AsInt(state.job.intervalMs, 3000) * state.failures
    if delay > 30000 then delay = 30000
    state.dueAt = now + delay
    return { key: key, ok: false, uri: "", error: reason }
end function

sub SnapshotPollerDrop(poller as Object, key as String)
    state = poller.jobs[key]
    if state = invalid then return
    if state.xfer <> invalid then
        state.xfer.AsyncCancel()
        poller.byTransfer.Delete(state.xfer.GetIdentity().ToStr())
        DeleteFile(state.file)
    end if
    for each file in state.files
        DeleteFile(file)
    end for
    poller.jobs.Delete(key)
end sub
