import winlean, os

type
  AlignedBuffer* = object
    base*: pointer
    start*: pointer

proc shallowAssign*(dest: var string, source: string) {.inline.} =
  if dest.len() >= source.len():
    dest.setLen(source.len())
    copyMem(cast[pointer](dest), cast[pointer](source), dest.len()*sizeof(char))
  else:
    dest = source

proc GetFinalPathNameByHandle(hFile: THandle,  lpszFilePath: pointer,
                              cchFilePath, dwFlags: Dword): Dword
  {.stdcall, dynlib: "kernel32", importc: "GetFinalPathNameByHandleW".}

proc getPath*(h: THandle, initSize = 80): string =
  ## Retrieves a path from a handle.
  var
    lastSize = initSize
    buffer = alloc0(initSize * sizeOf(TWinChar))

  while true:
    let bufSize = GetFinalPathNameByHandle(h, buffer, Dword(lastSize), Dword(0))
    if bufSize == 0:
      osError(osLastError())
    elif bufSize > lastSize:
      buffer = realloc(buffer, (bufSize + 1) * sizeOf(TWinChar))
      lastSize = bufSize + 1
      continue
    else:
      break
  buffer = cast[pointer](cast[int](buffer))
  result = $cast[WideCString](buffer)
  dealloc(buffer)


proc openDirHandle*(path: string, followSymlink=true): THandle =
  ## Open a directory handle suitable for use with ReadDirectoryChanges
  let accessFlags = (fileShareDelete or fileShareRead or fileShareWrite)
  var modeFlags = (fileFlagBackupSemantics or fileFlagOverlapped)
  if not followSymlink:
    modeFlags = modeFlags or fileFlagOpenReparsePoint

  when useWinUnicode:
    result = createFileW(newWideCString(path), fileListDirectory, accessFlags,
                         nil, openExisting, modeFlags, 0)
  else:
    result = createFileA(path, fileListDirectory, accessFlags,
                         nil, openExisting, modeFlags, 0)

  if result == invalidHandleValue:
    osError(osLastError())


proc openFileHandle*(path: string, followSymlink=true): THandle =
  var flags = FILE_FLAG_BACKUP_SEMANTICS or FILE_ATTRIBUTE_NORMAL
  if not followSymlink:
    flags = flags or FILE_FLAG_OPEN_REPARSE_POINT

  when useWinUnicode:
    result = createFileW(
      newWideCString(path), 0'i32, 
      FILE_SHARE_DELETE or FILE_SHARE_READ or FILE_SHARE_WRITE,
      nil, OPEN_EXISTING, flags, 0
      )
  else:
    result = createFileA(
      path, 0'i32, 
      FILE_SHARE_DELETE or FILE_SHARE_READ or FILE_SHARE_WRITE,
      nil, OPEN_EXISTING, flags, 0
      )
  if result == invalidHandleValue:
    osError(osLastError())
