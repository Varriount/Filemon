import os, asyncdispatch, winlean, utils, sets

type
  FileEvent* = enum
    feFileCreated
    feFileRemoved
    feFileModified
    feNameChangedNew
    feNameChangedOld

  FileEventCb* = proc (
    fileName: string, 
    eventKind: FileEvent,
    bufferOverflowed: bool
  ): PFuture[void]

  ChangeHandle* = ref object
    kind*: TPathComponent
    callback: FileEventCb
    handle: THandle
    cancelled: bool

  WatchData = ref object
    handle: THandle
    buffer: string
    ol: PCustomOverlapped

const
  allFileEvents* = {FileEvent.low .. FileEvent.high}

proc initWatchData(handle: THandle, bufferSize: int): WatchData =
  ## Initializes a watch data object. **Note**: The overlapped structure's
  ## refcount is incremented twice. You **must** use the cleanup procedure
  ## to cleanup the data's internal structures.
  new(result)
  new(result.ol)

  result.handle = handle
  result.ol.data.sock = TAsyncFd(handle)
  result.buffer = newString(bufferSize)
  GC_ref(result.ol)
  GC_ref(result.ol)

proc initWatchData(handle: THandle, bufferSize: int, cb: proc): WatchData =
  result = initWatchData(handle, bufferSize)
  result.ol.data.cb = cb

proc toFileEvent(action: dword): FileEvent =
  case action
  of FILE_ACTION_ADDED:
    result = feFileCreated
  of FILE_ACTION_REMOVED:
    result = feFileRemoved
  of FILE_ACTION_MODIFIED:
    result = feFileModified
  of FILE_ACTION_RENAMED_OLD_NAME:
    result = feNameChangedNew
  of FILE_ACTION_RENAMED_NEW_NAME:
    result = feNameChangedOld
  else:
    raise newException(EInvalidValue, "Invalid file action: " & $action)

proc toDword(actions: set[FileEvent]): dword =
  for a in actions:
    case a
    of feFileCreated:
      result = result or FILE_ACTION_ADDED
    of feFileRemoved:
      result = result or FILE_ACTION_REMOVED
    of feFileModified:
      result = result or FILE_ACTION_MODIFIED
    of feNameChangedNew:
      result = result or FILE_ACTION_RENAMED_OLD_NAME
    of feNameChangedOld:
      result = result or FILE_ACTION_RENAMED_NEW_NAME

proc callChanges(w: WatchData, bufferSize: Dword, filter: Dword): WinBool =
  result = ReadDirectoryChangesW(
    w.handle,
    cast[pointer](w.buffer),
    bufferSize,
    WinBool(false),
    filter,
    cast[ptr dword](nil),
    cast[POverlapped](w.ol),
    cast[LPOVERLAPPED_COMPLETION_ROUTINE](nil)
  )

iterator getChanges(buffer: pointer): tuple[path: string, event: FileEvent] =
  var
    data = cast[ptr FileNotifyInformation](buffer)
    result: tuple[path: string, event: FileEvent]
  result.path = ""

  while true:
    # We loop through the data buffer, parsing each chunk of data, then
    # moving to the next chunk of data via the offset.
    let
      offset = data.NextEntryOffset
      nameLength = data.FileNameLength
    result.path.setLen(nameLength)
    `$`(data.FileName, nameLength, result.path)
    result.event = data.Action.toFileEvent()
    echo("event address: ", cast[int](addr(result.event)))
    echo("event: ", result.event)
    echo("path address: ", cast[int](addr(result.path)))
    echo("path: ", `$`(data.FileName, nameLength))
    yield result

    if offset == 0:
      break
    data = cast[ptr FileNotifyInformation](cast[int](data) + offset)

proc cleanup(data: WatchData) =
  GC_unref(data.ol)
  GC_unref(data.ol)
  unregister(TAsyncFD(data.handle))
  discard closeHandle(data.handle)
  data.ol = nil

proc watchFile*(target: string, callback: FileEventCb, filter: set[FileEvent],
                bufferLen: int): ChangeHandle =
  ## Watch a file for changes, using ReadDirectoryChangesW plus a custom filter
  ## on Windows, inotify on Linux, and KQueues on OpenBSD/MacOSX. Note that
  ## although this procedure attempts to abstract away the behavioral
  ## differences in file event notifications across various platforms, there
  ## are still some differences in the behavior of this procedure across
  ## platforms.
  new(result)
  var
    res = result
    targetPath = target
    targetName = extractFileName(target)
    parentPath = parentDir(targetPath)
    targetHandle = openFileHandle(targetPath)
    parentHandle = openDirHandle(parentPath)

    bufferSize = Dword(bufferLen * sizeOf(char))
    rawFilter = toDword(filter) # Filter passed to readDirectoryChanges

    deadWatches = newSeq[WatchData]() # Sequence of dead watch data
    liveWatch = initWatchData(parentHandle, bufferLen) # The current watch

    lastEventWasRenamed = false

  proc rawEventCb(sock: TAsyncFD, bytesCount: DWord, errcode: TOSErrorCode) {.closure, gcsafe.} =
    # GC_fullcollect()
    var selectedWatch: WatchData # The watch that the socket belongs to.

    # Locate the set of data associated with the handle, and act upon it accordingly
    if THandle(sock) == liveWatch.handle:
      selectedWatch = liveWatch

      # Prevent the overlapped structure in the watch data from being collected:
      GC_ref(selectedWatch.ol)

      # Handle error codes
      var overflowed: bool
      if errcode == TOSErrorCode(ERROR_OPERATION_ABORTED):
        cleanup(liveWatch)
        liveWatch = nil
        return
      elif errcode == ERROR_NOTIFY_ENUM_DIR.TOSErrorCode:
        overflowed = true

      # Things to do if we aren't cancelled
      if not res.cancelled:

        # Handle file events
        # Change target name when overflowed, file deleted, or renamed
        for path, event in getChanges(cast[pointer](liveWatch.buffer)):
          if res.cancelled:
            break
          elif cmpPaths(targetName, extractFileName(path)) == 0:
            lastEventWasRenamed = (event == feNameChangedNew)
            discard callback(path, event, overflowed)
          elif lastEventWasRenamed:
            discard callback(path, event, overflowed)
            lastEventWasRenamed = false

        # Handle parent-child synchronization
        let
          newTargetPath = getPath(targetHandle)
          newParentPath = parentDir(newTargetPath)

        if cmpPaths(getPath(parentHandle), newParentPath) != 0:
          shallowAssign(targetPath, newTargetPath)
          shallowAssign(parentPath, newParentPath)
          parentHandle = openDirHandle(newParentPath)
          deadWatches.add(liveWatch)

          liveWatch = initWatchData(parentHandle, bufferLen, rawEventCb)
          register(TAsyncFD(liveWatch.handle))
          discard callChanges(selectedWatch, bufferSize, rawFilter)
          discard cancelIo(selectedWatch.handle)
      if callChanges(liveWatch, bufferSize, rawFilter) == WinBool(false):
        let error = osLastError()
        cleanup(liveWatch)
        osError(error)
      if res.cancelled:
        discard cancelIo(parentHandle)

    else:
      # Find the corresponding watch
      var
        dataIndex: int
      for index, watch in deadWatches:
        if THandle(sock) == watch.handle:
          selectedWatch = watch
          break

      # Prevent the overlapped structure in the watch data from being collected:
      GC_ref(selectedWatch.ol)

      # Handle the events
      if errcode == TOSErrorCode(ERROR_OPERATION_ABORTED):
        cleanup(selectedWatch)
        deadWatches.delete(dataIndex)
        return
      discard callChanges(selectedWatch, bufferSize, rawFilter)
      discard cancelIo(selectedWatch.handle)


  # GC_ref(ol)
  liveWatch.ol.data = TCompletionData(
    sock: TAsyncFD(parentHandle), 
    cb: rawEventCb
  )

  register(TAsyncFD(parentHandle))
  if callChanges(liveWatch, bufferSize, rawFilter) == WinBool(false):
    let error = osLastError()
    cleanup(liveWatch)
    osError(error)

  result.kind = pcFile
  result.handle = targetHandle
  result.callback = callback

when isMainModule:
  proc echoBack(name: string, event: FileEvent, overflowed: bool): PFuture[void] =
    echo "In callback"
    name.echo
    event.echo
    overflowed.echo

  # sleep(10000)
  let handle = watchFile(r"C:\Users\Clay\Projects\Nimrod-Scripts\testFolder\testFile.txt", echoBack, allFileEvents, 8000)
  runForever()